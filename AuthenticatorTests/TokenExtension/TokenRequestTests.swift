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

import CryptoKit
import Foundation
import Security
import Testing

@testable import OrielOTP

/// The request the token extension sends the app in a notification, and how the app checks the YubiKey's answer.
struct TokenRequestTests {

    private static let request = TokenRequest(
        operation: .signData, data: Data([1, 2, 3]), objectID: "object", keyType: .eccp256,
        algorithm: .ecdsaSignatureMessageX962SHA256, requestID: "request")

    @Test func roundTripsThroughTheNotification() {
        #expect(TokenRequest(userInfo: Self.request.userInfo) == Self.request)
    }

    /// A notification's user info comes back as a property list, with the key type as a plain integer.
    @Test func readsTheUserInfoAsAPropertyList() throws {
        let plist = try PropertyListSerialization.data(fromPropertyList: Self.request.userInfo, format: .binary, options: 0)
        let decoded = try #require(try PropertyListSerialization.propertyList(from: plist, format: nil) as? [AnyHashable: Any])
        #expect(TokenRequest(userInfo: decoded) == Self.request)
    }

    /// The extension only takes an answer filed under the request it's waiting for, so one without an ID isn't done.
    @Test(arguments: ["operationType", "data", "keyObjectID", "keyType", "algorithm", TokenResponseStore.requestIDKey])
    func needsEveryValue(_ key: String) {
        var userInfo = Self.request.userInfo
        userInfo[key] = nil
        #expect(TokenRequest(userInfo: userInfo) == nil)
    }

    @Test func turnsDownUnknownValues() {
        var userInfo = Self.request.userInfo
        userInfo["operationType"] = "performKeyExchange"
        #expect(TokenRequest(userInfo: userInfo) == nil)
        userInfo = Self.request.userInfo
        userInfo["keyType"] = 0x99
        #expect(TokenRequest(userInfo: userInfo) == nil)
        userInfo["keyType"] = 0x1_07
        #expect(TokenRequest(userInfo: userInfo) == nil)
    }

    @Test(arguments: [
        (kSecAttrKeyTypeRSA as String, 1024, TokenKeyType.rsa1024),
        (kSecAttrKeyTypeRSA as String, 2048, .rsa2048),
        (kSecAttrKeyTypeECSECPrimeRandom as String, 256, .eccp256),
        (kSecAttrKeyTypeECSECPrimeRandom as String, 384, .eccp384)
    ])
    func keyTypesOfAPIVSlot(_ type: String, _ size: Int, _ expected: TokenKeyType) {
        #expect(TokenKeyType(keyType: type, keySizeInBits: size) == expected)
    }

    @Test func turnsDownKeysAPIVSlotCantHold() {
        #expect(TokenKeyType(keyType: kSecAttrKeyTypeRSA as String, keySizeInBits: 4096) == nil)
        #expect(TokenKeyType(keyType: kSecAttrKeyTypeECSECPrimeRandom as String, keySizeInBits: 521) == nil)
        #expect(TokenKeyType(keyType: "ed25519", keySizeInBits: 256) == nil)
    }

    @Test func acceptsOnlyTheCertificatesKeysSignature() throws {
        let key = P256.Signing.PrivateKey()
        let other = P256.Signing.PrivateKey()
        let message = Data("message".utf8)
        let signature = try key.signature(for: message).derRepresentation
        let publicKey = try Self.secKey(key.publicKey.x963Representation)
        let otherPublicKey = try Self.secKey(other.publicKey.x963Representation)
        #expect(
            TokenRequestViewModel.verify(signature, data: message, publicKey: publicKey, algorithm: .ecdsaSignatureMessageX962SHA256) == nil
        )
        #expect(
            TokenRequestViewModel.verify(signature, data: message, publicKey: otherPublicKey, algorithm: .ecdsaSignatureMessageX962SHA256)
                != nil)
        #expect(
            TokenRequestViewModel.verify(
                signature, data: Data("other".utf8), publicKey: publicKey,
                algorithm: .ecdsaSignatureMessageX962SHA256) != nil)
    }

    private static func secKey(_ x963: Data) throws -> SecKey {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeyClass: kSecAttrKeyClassPublic]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(x963 as CFData, attributes as CFDictionary, &error) else {
            throw error!.takeRetainedValue() as Error
        }
        return key
    }
}
