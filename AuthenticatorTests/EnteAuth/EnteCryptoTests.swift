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

struct EnteCryptoTests {

    @Test func loginKeyMatchesLibsodiumKDF() throws {
        // BLAKE2b-256 keyed with the KEK, salt = subkey id 1 (LE) and personal = "loginctx", first 16 bytes.
        let loginKey = try EnteCrypto.deriveLoginKey(keyEncryptionKey: Data(repeating: 0x42, count: 32))
        #expect(loginKey == Data(hex: "40743fef4ad07599e23253cf1fdeb225"))
    }

    @Test func keyEncryptionKeyIsDeterministic() throws {
        let salt = Data(repeating: 1, count: EnteCrypto.saltLength)
        let first = try EnteCrypto.deriveKeyEncryptionKey(password: "password", salt: salt, opsLimit: 2, memLimit: 8 * 1024 * 1024)
        let second = try EnteCrypto.deriveKeyEncryptionKey(password: "password", salt: salt, opsLimit: 2, memLimit: 8 * 1024 * 1024)
        let otherSalt = try EnteCrypto.deriveKeyEncryptionKey(password: "password", salt: Data(repeating: 2, count: EnteCrypto.saltLength),
                                                              opsLimit: 2, memLimit: 8 * 1024 * 1024)
        #expect(first.count == 32)
        #expect(first == second)
        #expect(first != otherSalt)
        #expect(throws: EnteCryptoError.invalidLength) {
            try EnteCrypto.deriveKeyEncryptionKey(password: "password", salt: Data(count: 3), opsLimit: 2, memLimit: 8 * 1024 * 1024)
        }
    }

    @Test func secretBoxRoundTrip() throws {
        let key = EnteCrypto.randomBytes(32)
        let message = Data("master key".utf8)
        let (nonce, cipherText) = try EnteCrypto.secretBox(message, key: key)
        #expect(try EnteCrypto.secretBoxOpen(cipherText, nonce: nonce, key: key) == message)
        #expect(throws: EnteCryptoError.decryptionFailed) {
            try EnteCrypto.secretBoxOpen(cipherText, nonce: nonce, key: EnteCrypto.randomBytes(32))
        }
    }

    @Test func sealedBoxRoundTrip() throws {
        let (publicKey, secretKey) = try EnteCrypto.generateKeyPair()
        #expect(try EnteCrypto.publicKey(forSecretKey: secretKey) == publicKey)
        let sealed = try EnteCrypto.sealedBox(Data("token".utf8), publicKey: publicKey)
        #expect(try EnteCrypto.sealedBoxOpen(sealed, publicKey: publicKey, secretKey: secretKey) == Data("token".utf8))
        let other = try EnteCrypto.generateKeyPair()
        #expect(throws: EnteCryptoError.decryptionFailed) {
            try EnteCrypto.sealedBoxOpen(sealed, publicKey: other.publicKey, secretKey: other.secretKey)
        }
    }

    @Test func secretStreamRoundTrip() throws {
        let key = EnteCrypto.randomBytes(32)
        let message = Data("\"otpauth://totp/Example:alice?secret=JBSWY3DPEHPK3PXP\"".utf8)
        let (header, cipherText) = try EnteCrypto.secretStreamEncrypt(message, key: key)
        #expect(try EnteCrypto.secretStreamDecrypt(cipherText, header: header, key: key) == message)
        var tampered = cipherText
        tampered[tampered.count - 1] ^= 1
        #expect(throws: EnteCryptoError.decryptionFailed) {
            try EnteCrypto.secretStreamDecrypt(tampered, header: header, key: key)
        }
    }

    @Test func base64Variants() {
        let data = Data([0xfb, 0xff, 0xfe, 0x01])
        #expect(data.enteURLSafeBase64 == "-__-AQ==")
        #expect(Data(enteBase64: "-__-AQ==") == data)
        #expect(Data(enteBase64: "-__-AQ") == data)
        #expect(Data(enteBase64: "+//+AQ==") == data)
    }

    @Test func decryptsAccountKeys() async throws {
        let account = try FakeEnteAccount()
        let keys = try await EnteLoginFlow.decryptKeys(account.authResponse, keyEncryptionKey: account.keyEncryptionKey)
        #expect(keys.masterKey == account.masterKey)
        #expect(keys.token == account.token.enteURLSafeBase64)
        #expect(keys.userID == 42)
    }

    @Test func wrongPasswordIsReported() async throws {
        let account = try FakeEnteAccount()
        await #expect(throws: EnteLoginError.incorrectPassword) {
            try await EnteLoginFlow.decryptKeys(account.authResponse, keyEncryptionKey: EnteCrypto.randomBytes(32))
        }
    }

    @Test func mismatchedKeyPairIsRejected() async throws {
        let account = try FakeEnteAccount()
        var response = account.authResponse
        let other = try EnteCrypto.generateKeyPair()
        let attributes = response.keyAttributes!
        response.keyAttributes = EnteKeyAttributes(kekSalt: attributes.kekSalt, encryptedKey: attributes.encryptedKey,
                                                   keyDecryptionNonce: attributes.keyDecryptionNonce,
                                                   publicKey: other.publicKey.base64EncodedString(),
                                                   encryptedSecretKey: attributes.encryptedSecretKey,
                                                   secretKeyDecryptionNonce: attributes.secretKeyDecryptionNonce,
                                                   memLimit: attributes.memLimit, opsLimit: attributes.opsLimit)
        await #expect(throws: EnteLoginError.invalidAccountData) {
            try await EnteLoginFlow.decryptKeys(response, keyEncryptionKey: account.keyEncryptionKey)
        }
    }
}

/// An account encrypted the way Ente's server hands it out.
struct FakeEnteAccount {
    let keyEncryptionKey = EnteCrypto.randomBytes(32)
    let masterKey = EnteCrypto.randomBytes(32)
    let token = EnteCrypto.randomBytes(32)
    let authResponse: EnteAuthResponse

    init() throws {
        let (publicKey, secretKey) = try EnteCrypto.generateKeyPair()
        let encryptedKey = try EnteCrypto.secretBox(masterKey, key: keyEncryptionKey)
        let encryptedSecretKey = try EnteCrypto.secretBox(secretKey, key: masterKey)
        let attributes = EnteKeyAttributes(kekSalt: Data(count: 16).base64EncodedString(),
                                           encryptedKey: encryptedKey.cipherText.base64EncodedString(),
                                           keyDecryptionNonce: encryptedKey.nonce.base64EncodedString(),
                                           publicKey: publicKey.base64EncodedString(),
                                           encryptedSecretKey: encryptedSecretKey.cipherText.base64EncodedString(),
                                           secretKeyDecryptionNonce: encryptedSecretKey.nonce.base64EncodedString(),
                                           memLimit: 8 * 1024 * 1024, opsLimit: 2)
        authResponse = EnteAuthResponse(id: 42, keyAttributes: attributes,
                                        encryptedToken: try EnteCrypto.sealedBox(token, publicKey: publicKey).base64EncodedString())
    }
}
