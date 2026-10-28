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
import Clibsodium

enum EnteCryptoError: Error, Equatable {
    case sodiumInitFailed
    case keyDerivationFailed
    case invalidLength
    case decryptionFailed
    case encryptionFailed
}

/// The libsodium primitives Ente uses, with the same parameters as Ente's own clients.
///
/// - Key encryption key: Argon2id over the password with the account's salt and limits.
/// - Login key for SRP: the first 16 bytes of `crypto_kdf_derive_from_key(32, 1, "loginctx", kek)`.
/// - Master and secret key: XSalsa20-Poly1305 secretbox.
/// - Auth token: an anonymous sealed box to the account's X25519 public key.
/// - Authenticator entities: a single XChaCha20-Poly1305 secretstream message.
nonisolated enum EnteCrypto {

    static let keyLength = Int(crypto_secretbox_keybytes())
    static let saltLength = Int(crypto_pwhash_saltbytes())

    private static let isInitialized: Bool = sodium_init() >= 0

    private static func ensureInitialized() throws {
        guard isInitialized else { throw EnteCryptoError.sodiumInitFailed }
    }

    /// Derives the key encryption key. This is slow and memory hungry by design, call it off the main actor.
    static func deriveKeyEncryptionKey(password: String, salt: Data, opsLimit: UInt64, memLimit: UInt64) throws -> Data {
        try ensureInitialized()
        guard salt.count == saltLength else { throw EnteCryptoError.invalidLength }
        var key = [UInt8](repeating: 0, count: keyLength)
        let password = Array(password.utf8CString.dropLast())
        defer { sodium_memzero(&key, key.count) }
        guard crypto_pwhash(&key, UInt64(keyLength), password, UInt64(password.count), [UInt8](salt),
                            opsLimit, Int(memLimit), crypto_pwhash_ALG_ARGON2ID13) == 0 else {
            throw EnteCryptoError.keyDerivationFailed
        }
        return Data(key)
    }

    /// Derives the 16 byte SRP password from the key encryption key.
    static func deriveLoginKey(keyEncryptionKey: Data) throws -> Data {
        try ensureInitialized()
        guard keyEncryptionKey.count == Int(crypto_kdf_keybytes()) else { throw EnteCryptoError.invalidLength }
        var subkey = [UInt8](repeating: 0, count: 32)
        defer { sodium_memzero(&subkey, subkey.count) }
        let context = Array("loginctx".utf8CString)
        guard crypto_kdf_derive_from_key(&subkey, subkey.count, 1, context, [UInt8](keyEncryptionKey)) == 0 else {
            throw EnteCryptoError.keyDerivationFailed
        }
        return Data(subkey.prefix(16))
    }

    static func secretBoxOpen(_ cipherText: Data, nonce: Data, key: Data) throws -> Data {
        try ensureInitialized()
        let macLength = Int(crypto_secretbox_macbytes())
        guard cipherText.count >= macLength,
              nonce.count == Int(crypto_secretbox_noncebytes()),
              key.count == keyLength else { throw EnteCryptoError.invalidLength }
        var message = [UInt8](repeating: 0, count: cipherText.count - macLength)
        guard crypto_secretbox_open_easy(&message, [UInt8](cipherText), UInt64(cipherText.count), [UInt8](nonce), [UInt8](key)) == 0 else {
            throw EnteCryptoError.decryptionFailed
        }
        return Data(message)
    }

    /// Returns the nonce and the cipher text.
    static func secretBox(_ message: Data, key: Data) throws -> (nonce: Data, cipherText: Data) {
        try ensureInitialized()
        guard key.count == keyLength else { throw EnteCryptoError.invalidLength }
        let nonce = randomBytes(Int(crypto_secretbox_noncebytes()))
        var cipherText = [UInt8](repeating: 0, count: message.count + Int(crypto_secretbox_macbytes()))
        guard crypto_secretbox_easy(&cipherText, [UInt8](message), UInt64(message.count), [UInt8](nonce), [UInt8](key)) == 0 else {
            throw EnteCryptoError.encryptionFailed
        }
        return (nonce, Data(cipherText))
    }

    /// Derives the public key of a secret key, used to check that a key pair belongs together.
    static func publicKey(forSecretKey secretKey: Data) throws -> Data {
        try ensureInitialized()
        guard secretKey.count == Int(crypto_box_secretkeybytes()) else { throw EnteCryptoError.invalidLength }
        var publicKey = [UInt8](repeating: 0, count: Int(crypto_box_publickeybytes()))
        guard crypto_scalarmult_base(&publicKey, [UInt8](secretKey)) == 0 else { throw EnteCryptoError.keyDerivationFailed }
        return Data(publicKey)
    }

    static func sealedBoxOpen(_ cipherText: Data, publicKey: Data, secretKey: Data) throws -> Data {
        try ensureInitialized()
        let sealLength = Int(crypto_box_sealbytes())
        guard cipherText.count >= sealLength,
              publicKey.count == Int(crypto_box_publickeybytes()),
              secretKey.count == Int(crypto_box_secretkeybytes()) else { throw EnteCryptoError.invalidLength }
        var message = [UInt8](repeating: 0, count: cipherText.count - sealLength)
        guard crypto_box_seal_open(&message, [UInt8](cipherText), UInt64(cipherText.count), [UInt8](publicKey), [UInt8](secretKey)) == 0 else {
            throw EnteCryptoError.decryptionFailed
        }
        return Data(message)
    }

    static func sealedBox(_ message: Data, publicKey: Data) throws -> Data {
        try ensureInitialized()
        guard publicKey.count == Int(crypto_box_publickeybytes()) else { throw EnteCryptoError.invalidLength }
        var cipherText = [UInt8](repeating: 0, count: message.count + Int(crypto_box_sealbytes()))
        guard crypto_box_seal(&cipherText, [UInt8](message), UInt64(message.count), [UInt8](publicKey)) == 0 else {
            throw EnteCryptoError.encryptionFailed
        }
        return Data(cipherText)
    }

    static func generateKeyPair() throws -> (publicKey: Data, secretKey: Data) {
        try ensureInitialized()
        var publicKey = [UInt8](repeating: 0, count: Int(crypto_box_publickeybytes()))
        var secretKey = [UInt8](repeating: 0, count: Int(crypto_box_secretkeybytes()))
        guard crypto_box_keypair(&publicKey, &secretKey) == 0 else { throw EnteCryptoError.keyDerivationFailed }
        return (Data(publicKey), Data(secretKey))
    }

    /// Decrypts data that was encrypted as one secretstream message, the way Ente stores authenticator entities.
    static func secretStreamDecrypt(_ cipherText: Data, header: Data, key: Data) throws -> Data {
        try ensureInitialized()
        let additionalLength = Int(crypto_secretstream_xchacha20poly1305_abytes())
        guard cipherText.count >= additionalLength,
              header.count == Int(crypto_secretstream_xchacha20poly1305_headerbytes()),
              key.count == Int(crypto_secretstream_xchacha20poly1305_keybytes()) else { throw EnteCryptoError.invalidLength }
        var state = crypto_secretstream_xchacha20poly1305_state()
        guard crypto_secretstream_xchacha20poly1305_init_pull(&state, [UInt8](header), [UInt8](key)) == 0 else {
            throw EnteCryptoError.decryptionFailed
        }
        var message = [UInt8](repeating: 0, count: cipherText.count - additionalLength)
        var messageLength: UInt64 = 0
        var tag: UInt8 = 0
        guard crypto_secretstream_xchacha20poly1305_pull(&state, &message, &messageLength, &tag,
                                                         [UInt8](cipherText), UInt64(cipherText.count), nil, 0) == 0 else {
            throw EnteCryptoError.decryptionFailed
        }
        return Data(message.prefix(Int(messageLength)))
    }

    /// Encrypts data as one final secretstream message. Returns the header and the cipher text.
    static func secretStreamEncrypt(_ message: Data, key: Data) throws -> (header: Data, cipherText: Data) {
        try ensureInitialized()
        guard key.count == Int(crypto_secretstream_xchacha20poly1305_keybytes()) else { throw EnteCryptoError.invalidLength }
        var state = crypto_secretstream_xchacha20poly1305_state()
        var header = [UInt8](repeating: 0, count: Int(crypto_secretstream_xchacha20poly1305_headerbytes()))
        guard crypto_secretstream_xchacha20poly1305_init_push(&state, &header, [UInt8](key)) == 0 else {
            throw EnteCryptoError.encryptionFailed
        }
        var cipherText = [UInt8](repeating: 0, count: message.count + Int(crypto_secretstream_xchacha20poly1305_abytes()))
        guard crypto_secretstream_xchacha20poly1305_push(&state, &cipherText, nil, [UInt8](message), UInt64(message.count),
                                                         nil, 0, UInt8(crypto_secretstream_xchacha20poly1305_TAG_FINAL)) == 0 else {
            throw EnteCryptoError.encryptionFailed
        }
        return (Data(header), Data(cipherText))
    }

    static func randomBytes(_ count: Int) -> Data {
        _ = isInitialized
        var bytes = [UInt8](repeating: 0, count: count)
        randombytes_buf(&bytes, count)
        return Data(bytes)
    }
}

nonisolated extension Data {

    /// Ente sends most binary values as standard Base64 and the auth token as URL-safe Base64.
    init?(enteBase64 string: String) {
        var normalized = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        self.init(base64Encoded: normalized)
    }

    /// URL-safe Base64 with padding, the encoding Ente's clients use for the X-Auth-Token header.
    var enteURLSafeBase64: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }
}
