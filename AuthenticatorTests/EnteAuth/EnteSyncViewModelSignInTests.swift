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

#if DEBUG && (targetEnvironment(simulator) || os(macOS))

import Foundation
import Testing

@testable import OrielOTP

/// Signs in on the sign in screen's view model against the fake Ente server, checking the password doesn't stay behind.
/// Serialized as the request log is shared.
@Suite(.serialized) @MainActor struct EnteSyncViewModelSignInTests {

    private func model(protocols: [AnyClass] = [FakeEnteServer.self]) -> EnteSyncViewModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = protocols
        // The session is kept in memory: the Mac build CI tests is signed without the keychain access group.
        let defaults = makeTestDefaults()
        let store = EnteSessionStore(keychain: InMemoryKeychain(), defaults: defaults, canSave: true)
        let session = URLSession(configuration: configuration)
        let watch = WatchAccountSync(defaults: defaults)
        let model = EnteSyncViewModel(existingCredentialIds: [], store: store, defaults: defaults, session: session, watch: watch,
                                      cloud: EnteCloud(store: store, storage: InMemoryVaultStorage(), session: session, watch: watch))
        model.server = FakeEnteServer.server.absoluteString
        return model
    }

    private func signIn(_ model: EnteSyncViewModel, email: String) async throws {
        model.email = email
        model.password = FakeEnteServer.password
        model.signIn()
        try await finish(model)
    }

    private func finish(_ model: EnteSyncViewModel) async throws {
        while model.isBusy {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func cancelAfterTheEmailCodeForgetsTheSignIn() async throws {
        let model = model()
        try await signIn(model, email: "alice+mfa@example.com")
        #expect(model.phase == .emailCode)
        #expect(model.flow != nil)
        #expect(model.password.isEmpty)
        model.code = "123"
        model.close()
        #expect(model.flow == nil)
        #expect(model.password.isEmpty)
        #expect(model.code.isEmpty)
    }

    @Test func cancelWhileSigningInForgetsThePassword() async throws {
        let log = RequestLog.Paths()
        RequestLog.current = log
        let model = model(protocols: [RequestLog.self, FakeEnteServer.self])
        model.email = "alice+mfa@example.com"
        model.password = FakeEnteServer.password
        model.signIn()
        // Closes while the server is asked to send the email code, the flow holding the password comes after.
        try await log.wait(for: "/users/ott")
        model.close()
        try await finish(model)
        #expect(model.flow == nil)
        #expect(model.password.isEmpty)
        #expect(model.phase == .signIn)
        #expect(model.error == nil)
    }

    @Test func cancelWhileReadingTheAuthenticatorKeyEndsTheSession() async throws {
        let log = RequestLog.Paths()
        RequestLog.current = log
        let model = model(protocols: [RequestLog.self, FakeEnteServer.self])
        model.email = "alice@example.com"
        model.password = FakeEnteServer.password
        model.signIn()
        try await log.wait(for: "/authenticator/key")
        model.close()
        try await finish(model)
        try await log.wait(for: "/users/logout")
        #expect(model.signedInEmail == nil)
        #expect(model.phase == .signIn)
        #expect(model.error == nil)
        #expect(!model.isSessionSaved)
    }

    @Test func wrongPasswordStopsDerivingKeys() async throws {
        let model = model()
        model.email = "alice@example.com"
        model.password = "wrong"
        model.signIn()
        try await finish(model)
        #expect(model.error != nil)
        #expect(model.phase == .signIn)
        #expect(!model.isDerivingKeys)
    }

    @Test func failingToSendTheEmailCodeForgetsThePassword() async throws {
        let model = model(protocols: [FailingEmailCode.self, FakeEnteServer.self])
        try await signIn(model, email: "alice+mfa@example.com")
        #expect(model.error != nil)
        #expect(model.phase == .signIn)
        #expect(model.flow == nil)
        #expect(model.password.isEmpty)
    }

    @Test func wrongPasswordAfterTheEmailCodeOnlyAsksForThePassword() async throws {
        let model = model()
        model.email = "alice+mfa@example.com"
        model.password = "wrong"
        model.signIn()
        try await finish(model)
        #expect(model.phase == .emailCode)
        model.code = FakeEnteServer.code
        model.submitCode()
        try await finish(model)
        #expect(model.phase == .signIn)
        #expect(model.password.isEmpty)
        #expect(model.flow?.needsPassword == true)
        model.password = FakeEnteServer.password
        model.signIn()
        try await finish(model)
        #expect(model.error == nil)
        #expect(model.phase == .accounts)
        #expect(model.password.isEmpty)
        #expect(!model.isDerivingKeys)
        model.close()
    }
}

/// Notes the paths of the requests on their way to the fake server, which answers them.
nonisolated private final class RequestLog: URLProtocol, @unchecked Sendable {

    nonisolated(unsafe) static var current: RequestLog.Paths?

    final class Paths: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: Set<String> = []

        func insert(_ path: String) {
            lock.withLock { _ = paths.insert(path) }
        }

        func contains(_ path: String) -> Bool {
            lock.withLock { paths.contains(path) }
        }

        func wait(for path: String) async throws {
            // Signing in can take most of a minute on CI.
            let deadline = ContinuousClock.now + .seconds(120)
            while !contains(path) {
                guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        if let path = request.url?.path {
            current?.insert(path)
        }
        return false
    }
}

/// Fails sending the email code, letting everything else through to the fake server.
nonisolated private final class FailingEmailCode: URLProtocol, @unchecked Sendable {

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path == "/users/ott"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

#endif
