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

/// Fails every request that reaches it, the last protocol of every test session, so that a request no stub answers
/// fails instead of going out to the network.
nonisolated final class UnexpectedRequestFailure: URLProtocol, @unchecked Sendable {

    static let errorDomain = "OrielOTPTests.UnexpectedRequest"

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: NSError(domain: Self.errorDomain, code: 1, userInfo: [
            NSLocalizedDescriptionKey: "No stub answers \(request.url?.absoluteString ?? "")"]))
    }

    override func stopLoading() {}
}

extension URLSession {

    /// A session for tests, which keeps nothing on disk. The stubs answer in their order, and any request none of them
    /// takes fails without reaching the network.
    ///
    /// Signing in with 4096-bit SRP takes the fake server longer than URLSession's default 60 second timeout in an
    /// unoptimised build. The stubs answer locally, so a long timeout costs nothing.
    nonisolated static func stubbed(_ protocols: [AnyClass]) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = protocols + [UnexpectedRequestFailure.self]
        configuration.timeoutIntervalForRequest = 3600
        configuration.timeoutIntervalForResource = 3600
        return URLSession(configuration: configuration)
    }
}

import Testing

@testable import OrielOTP

/// No test may reach a real server. ".invalid" never resolves, so these can't reach one either if this ever breaks.
struct NoNetworkInTestsTests {

    private static let unknownHost = URL(string: "https://api.example.invalid/users/srp/attributes")!

    @Test func aRequestNoStubAnswersFails() async {
        let error = await #expect(throws: (any Error).self) {
            try await URLSession.stubbed([]).data(from: Self.unknownHost)
        }
        #expect((error as? NSError)?.domain == UnexpectedRequestFailure.errorDomain)
    }

    #if DEBUG && (targetEnvironment(simulator) || os(macOS))
    @Test func theAppsSessionAnswersOnlyFromTheFakeServer() async {
        let error = await #expect(throws: (any Error).self) {
            try await URLSession.ente.data(from: Self.unknownHost)
        }
        #expect((error as? NSError)?.domain == UnstubbedRequestFailure.errorDomain)
    }
    #endif
}
