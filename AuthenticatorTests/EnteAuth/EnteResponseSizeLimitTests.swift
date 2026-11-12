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
import Testing

@testable import OrielOTP

/// Answers every request to its host with a 200 whose JSON body is preceded by 64 MiB of spaces, which JSON allows.
nonisolated private final class OversizedBodyServer: URLProtocol, @unchecked Sendable {
    static let host = "oversized.ente.test"

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let chunk = Data(repeating: 0x20, count: 1024 * 1024)
        for _ in 0..<64 {
            client?.urlProtocol(self, didLoad: chunk)
        }
        client?.urlProtocol(self, didLoad: Data(#"{"diff":[]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// The API client stops reading an answer far larger than any Ente gives.
struct EnteResponseSizeLimitTests {

    @Test func aResponseFarLargerThanAnyEnteAnswerIsRefused() async throws {
        let server = try #require(URL(string: "https://\(OversizedBodyServer.host)"))
        let api = try EnteAPIClient(server: server, session: URLSession.stubbed([OversizedBodyServer.self]))
        // A diff page of 500 entities is well under 1 MiB. 64 MiB of anything should not be read, let alone decoded.
        await #expect(throws: (any Error).self) {
            _ = try await api.authenticatorDiff(token: "token", sinceTime: 0, limit: 500)
        }
    }
}
