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
import os

enum EnteCryptoError: Error, Equatable {
    case sodiumInitFailed
    case keyDerivationFailed
    case invalidKeyLimits
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
        guard isAllowed(opsLimit: opsLimit, memLimit: memLimit) else { throw EnteCryptoError.invalidKeyLimits }
        var key = [UInt8](repeating: 0, count: keyLength)
        let password = Array(password.utf8CString.dropLast())
        defer { sodium_memzero(&key, key.count) }
        guard crypto_pwhash(&key, UInt64(keyLength), password, UInt64(password.count), [UInt8](salt),
                            opsLimit, Int(memLimit), crypto_pwhash_ALG_ARGON2ID13) == 0 else {
            throw EnteCryptoError.keyDerivationFailed
        }
        return Data(key)
    }

    /// Turns the password of a new account into a key encryption key. Ente's server only takes limits with exactly the
    /// work of libsodium's sensitive limits, so devices short of memory halve it and double the passes, like Ente's apps.
    /// This is slow and memory hungry by design, call it off the main actor.
    static func deriveNewKeyEncryptionKey(password: String) throws -> (key: Data, salt: Data, opsLimit: UInt64, memLimit: UInt64) {
        let salt = randomBytes(saltLength)
        let limits = newKeyLimits(availableMemory: availableMemory())
        for (index, limit) in limits.enumerated() {
            do {
                let key = try deriveKeyEncryptionKey(password: password, salt: salt, opsLimit: limit.opsLimit, memLimit: limit.memLimit)
                return (key, salt, limit.opsLimit, limit.memLimit)
            } catch EnteCryptoError.keyDerivationFailed where index < limits.count - 1 {
                continue
            }
        }
        throw EnteCryptoError.keyDerivationFailed
    }

    /// The limits to try for a new account, in order. Like Ente's apps, this starts from libsodium's sensitive limits
    /// (1 GiB, 4 passes) and, when the memory can't be had, halves it and doubles the passes, down to 128 MiB, the least
    /// Ente's server takes. Memory times passes stays the same.
    ///
    /// Running out of memory on iOS ends the app rather than failing the allocation, so limits that wouldn't leave
    /// 256 MiB of the memory the app may still use are skipped. `availableMemory` is nil where that isn't known.
    static func newKeyLimits(availableMemory: UInt64?) -> [(opsLimit: UInt64, memLimit: UInt64)] {
        let headroom: UInt64 = 256 * 1024 * 1024
        let minMemory: UInt64 = 128 * 1024 * 1024
        var memLimit = UInt64(crypto_pwhash_memlimit_sensitive())
        var opsLimit = UInt64(crypto_pwhash_opslimit_sensitive())
        var limits: [(opsLimit: UInt64, memLimit: UInt64)] = []
        while true {
            if memLimit == minMemory || availableMemory.map({ $0 >= memLimit + headroom }) ?? true {
                limits.append((opsLimit, memLimit))
            }
            guard memLimit > minMemory else { return limits }
            memLimit /= 2
            opsLimit *= 2
        }
    }

    /// How much more memory the app may use before the system ends it, where that's known.
    private static func availableMemory() -> UInt64? {
        #if os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
        // Where there's no such limit, as in the simulator, this is 0.
        let available = os_proc_available_memory()
        return available > 0 ? UInt64(available) : nil
        #else
        return nil
        #endif
    }

    /// Whether Argon2 limits sent by a server are safe to use. The limits come with the account and aren't
    /// authenticated, so a server could otherwise have the password hashed cheaply, and then guess it from the SRP
    /// proof, or run the app out of memory or keep it busy for minutes, which can't be cancelled.
    ///
    /// Ente's clients start from libsodium's sensitive limits (1 GiB, 4 passes) and double the passes as they halve the
    /// memory on devices that need it, which leaves memory times passes the same. So the memory must be between
    /// libsodium's interactive and sensitive limits (64 MiB to 1 GiB), with at least the interactive limits' 2 passes,
    /// and memory times passes at most that of the sensitive limits, 4 GiB. The floor keeps older accounts, made with
    /// the interactive or moderate limits, working.
    static func isAllowed(opsLimit: UInt64, memLimit: UInt64) -> Bool {
        let minMemory = UInt64(crypto_pwhash_memlimit_interactive())
        let maxMemory = UInt64(crypto_pwhash_memlimit_sensitive())
        let maxWork = maxMemory * UInt64(crypto_pwhash_opslimit_sensitive())
        let (work, overflow) = memLimit.multipliedReportingOverflow(by: opsLimit)
        return opsLimit >= UInt64(crypto_pwhash_opslimit_interactive()) && (minMemory...maxMemory).contains(memLimit)
            && !overflow && work <= maxWork
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

    /// Decrypts data that was encrypted as one final secretstream message, the way Ente stores authenticator entities.
    /// A message without the final tag is refused: it would be the start of a longer stream, cut short.
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
                                                         [UInt8](cipherText), UInt64(cipherText.count), nil, 0) == 0,
              tag == UInt8(crypto_secretstream_xchacha20poly1305_TAG_FINAL) else {
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
