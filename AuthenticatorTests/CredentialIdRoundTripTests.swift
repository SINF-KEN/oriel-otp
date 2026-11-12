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
import YubiKit

@testable import OrielOTP

/// The ids the app builds for accounts on a YubiKey, written to the simulated YubiKey and listed back through
/// YubiKit's own parser, which is internal to YubiKit and so can only be reached this way.
@Suite(.serialized)
struct CredentialIdRoundTripTests {

    private static let secret = Data(base32Encoded: "JBSWY3DPEHPK3PXP")!

    /// Adds the template to an empty simulated YubiKey and lists it back. The simulator's own key is put back after.
    private func roundTrip(_ template: YubiKitOATHSession.CredentialTemplate) async throws -> YubiKitOATHSession.Credential {
        let saved = UserDefaults.standard.data(forKey: "SimulatedYubiKey")
        defer { UserDefaults.standard.set(saved, forKey: "SimulatedYubiKey") }
        let storage = SimulatedYubiKeyStorage()
        storage.withState {
            $0.credentials = []
            $0.accessKey = nil
        }
        let session = try await YubiKitOATHSession.makeSession(connection: SimulatedYubiKeyConnection(storage: storage))
        _ = try await session.addCredential(template: template)
        return try #require(try await session.listCredentials().first)
    }

    private func template(issuer: String?, name: String, period: TimeInterval?) throws -> YubiKitOATHSession.CredentialTemplate {
        try YubiKitOATHSession.CredentialTemplate(type: period.map { .totp(period: $0) } ?? .hotp(counter: 0), algorithm: .sha1,
                                                  secret: Self.secret, issuer: issuer, accountName: name, digits: 6)
    }

    @Test(arguments: [
        ("GitHub", "alice@example.com", 30.0),
        ("Bank", "alice", 60.0),
        (nil, "alice", 30.0),
        (nil, "alice", 15.0),
        ("Example Inc.", "alice:work", 30.0),
    ] as [(String?, String, Double)])
    func totpIdsReadBackTheSame(issuer: String?, name: String, period: Double) async throws {
        let template = try template(issuer: issuer, name: name, period: period)
        let key = OATHCredentialId.key(accountName: name, issuer: issuer, period: UInt(period), isTOTP: true)
        // The app's id is the one YubiKit writes...
        #expect(key == template.identifier)
        #expect(OATHCredentialId.readsBack(key, period: UInt(period), isTOTP: true))
        // ...and YubiKit reads it back with the same period.
        let credential = try await roundTrip(template)
        #expect(credential.type.period == period)
        #expect(OATHCredentialId.key(accountName: credential.name, issuer: credential.issuer,
                                     period: UInt(credential.type.period ?? 0), isTOTP: true) == key)
    }

    @Test func hotpIdsHaveNoPeriod() async throws {
        let template = try template(issuer: "Bank", name: "alice", period: nil)
        let key = OATHCredentialId.key(accountName: "alice", issuer: "Bank", period: 0, isTOTP: false)
        #expect(key == "Bank:alice")
        #expect(key == template.identifier)
        let credential = try await roundTrip(template)
        #expect(credential.type.period == nil)
        #expect(credential.issuer == "Bank")
        #expect(credential.name == "alice")
    }

    /// The names `readsBack` turns down, which the app refuses to add, are ones YubiKit reads back with another period.
    @Test(arguments: [("24/7 Fitness", "alice"), (nil, "0/alice")] as [(String?, String)])
    func idsThatLookLikeAPeriodAreTurnedDown(issuer: String?, name: String) async throws {
        let key = OATHCredentialId.key(accountName: name, issuer: issuer, period: 30, isTOTP: true)
        #expect(!OATHCredentialId.readsBack(key, period: 30, isTOTP: true))
        #expect(throws: CredentialTemplateError.periodLikeName) { try template(issuer: issuer, name: name, period: 30) }
        guard name != "0/alice" else { return } // A period of 0 traps when YubiKit lists it.
        // Written past the app's check, YubiKit reads the issuer's "24/" as a period of 24 seconds.
        let unchecked = YubiKitOATHSession.CredentialTemplate(type: .totp(period: 30), algorithm: .sha1, secret: Self.secret,
                                                             issuer: issuer, name: name, digits: 6)
        let credential = try await roundTrip(unchecked)
        #expect(credential.type.period == 24)
    }
}

#endif
