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

struct EnteRedirectTests {

    private static let origin = "https://api.ente.io/users/ott"

    @Test(arguments: [
        "https://api.ente.io/v2/users/ott",
        "HTTPS://API.ENTE.IO/users/ott",
        "https://api.ente.io:443/users/ott"
    ]) func aRedirectOnTheSameServerIsFollowed(destination: String) {
        #expect(EnteRedirectGuard.allows(from: URL(string: Self.origin), to: URL(string: destination)))
    }

    @Test(arguments: [
        "http://api.ente.io/users/ott",
        "https://evil.example/users/ott",
        "https://api.ente.io.evil.example/users/ott",
        "https://api.ente.io:8443/users/ott",
        "https://evil.example@evil.example/users/ott",
        "ftp://api.ente.io/users/ott"
    ]) func aRedirectAnywhereElseIsRefused(destination: String) {
        #expect(!EnteRedirectGuard.allows(from: URL(string: Self.origin), to: URL(string: destination)))
    }

    @Test func aRefusedRedirectDoesNotCarryTheTokenAway() async throws {
        let url = try #require(URL(string: Self.origin))
        var request = URLRequest(url: url)
        request.setValue("token", forHTTPHeaderField: "X-Auth-Token")
        let task = URLSession.ente.dataTask(with: request)
        defer { task.cancel() }
        let response = try #require(HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: nil))
        var redirected = request
        redirected.url = URL(string: "https://evil.example/collect")

        let followed = await withCheckedContinuation { continuation in
            EnteRedirectGuard().urlSession(.ente, task: task, willPerformHTTPRedirection: response, newRequest: redirected) {
                continuation.resume(returning: $0)
            }
        }
        #expect(followed == nil)
    }

    @Test func theSessionKeepsNothingOnDiskAndChecksRedirects() {
        #expect(URLSession.ente.delegate is EnteRedirectGuard)
        #expect(URLSession.ente.configuration.urlCache?.diskCapacity ?? 0 == 0)
    }

    /// A cookie the server sets stays in the session's own store, in memory, and never reaches the app's shared store,
    /// which is kept on disk. Fails if the session uses the default configuration.
    @Test func cookiesStayOutOfTheSharedStore() throws {
        let storage = try #require(URLSession.ente.configuration.httpCookieStorage)
        #expect(storage !== HTTPCookieStorage.shared)
        let url = try #require(URL(string: "https://cookie-test.ente.invalid/users/ott"))
        let name = "OrielCookieTest-\(UUID().uuidString)"
        let cookie = try #require(
            HTTPCookie(properties: [
                .name: name, .value: "1", .domain: "cookie-test.ente.invalid",
                .path: "/", .expires: Date().addingTimeInterval(3600)
            ]))
        storage.setCookies([cookie], for: url, mainDocumentURL: nil)
        defer { storage.deleteCookie(cookie) }

        #expect(storage.cookies(for: url)?.contains { $0.name == name } == true)
        #expect(HTTPCookieStorage.shared.cookies(for: url)?.contains { $0.name == name } != true)
    }
}
