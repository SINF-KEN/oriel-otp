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

/// Answers every request with an empty diff and the `Date` set in `serverTime`, so a test can set the server's clock.
nonisolated final class DatedURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var serverTime = Date()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Date": formatter.string(from: Self.serverTime)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"diff":[]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized)
struct ServerClockTests {

    private let header = "Sun, 06 Nov 1994 08:49:37 GMT"
    private var serverDate: Date { Date(timeIntervalSince1970: 784_111_777) }

    @Test func readsAnHTTPDate() {
        #expect(EnteServerClock.parse(header) == serverDate)
        #expect(EnteServerClock.parse("yesterday") == nil)
    }

    @Test func aRightClockIsntReported() throws {
        let measurement = try #require(
            EnteServerClock.measure(dateHeader: header, sent: serverDate, received: serverDate.addingTimeInterval(0.2)))
        #expect(abs(measurement.offset) < 1)
        #expect(measurement.skew == nil)
    }

    @Test func aClockBehindIsReported() throws {
        let sent = serverDate.addingTimeInterval(-125)
        let measurement = try #require(EnteServerClock.measure(dateHeader: header, sent: sent, received: sent.addingTimeInterval(1)))
        let skew = try #require(measurement.skew)
        #expect(abs(skew - 125) < 1)
    }

    @Test func aClockAheadIsReported() throws {
        let sent = serverDate.addingTimeInterval(60)
        let skew = try #require(EnteServerClock.measure(dateHeader: header, sent: sent, received: sent)?.skew)
        #expect(skew < -59 && skew > -61)
    }

    /// Only an offset that's certainly over 30 seconds, whatever the time the answer took, is reported.
    @Test func anUncertainOffsetIsntReported() throws {
        let sent = serverDate.addingTimeInterval(-36)
        // Answered after 8 seconds: the server's time could be anywhere in them.
        let measurement = try #require(EnteServerClock.measure(dateHeader: header, sent: sent, received: sent.addingTimeInterval(8)))
        #expect(measurement.skew == nil)
        // Too slow an answer says nothing.
        #expect(EnteServerClock.measure(dateHeader: header, sent: sent, received: sent.addingTimeInterval(11)) == nil)
        #expect(EnteServerClock.measure(dateHeader: nil, sent: sent, received: sent) == nil)
    }

    @Test func theAmountIsReadable() {
        #expect(ClockWarningRow.amount(125.4).contains("2"))
        #expect(ClockWarningRow.amount(-45) == ClockWarningRow.amount(45))
    }

    /// A sync with a server whose clock is two minutes ahead of this device's shows the warning, and one that agrees
    /// takes it away.
    @MainActor @Test func aSyncFindsTheClockOff() async throws {
        let defaults = makeTestDefaults()
        let cloud = EnteCloud(
            store: EnteSessionStore(keychain: InMemoryKeychain(), defaults: defaults, canSave: true),
            storage: InMemoryVaultStorage(), session: URLSession.stubbed([DatedURLProtocol.self]),
            watch: WatchAccountSync(defaults: defaults))
        cloud.use(
            EnteSavedSession(
                server: URL(string: "https://ente.test")!, email: "a@b.c", token: "t",
                authenticatorKey: EnteCrypto.randomBytes(32)))
        DatedURLProtocol.serverTime = Date().addingTimeInterval(120)
        try await cloud.syncNow()
        let skew = try #require(cloud.clockSkew)
        #expect(skew > 115 && skew < 125)

        DatedURLProtocol.serverTime = Date()
        try await cloud.syncNow()
        #expect(cloud.clockSkew == nil)
    }
}
