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

enum EnteSignUpError: Error, LocalizedError, Equatable {
    case notAllowedOnEnte
    case registrationDisabled
    case accountExists
    case notVerified
    case passwordTooShort
    case passwordsDiffer

    var errorDescription: String? {
        switch self {
        case .notAllowedOnEnte:
            return String(localized: "Accounts can't be created on Ente's servers here. Create one in Ente's apps, or use a server you host yourself.", comment: "Ente account creation error")
        case .registrationDisabled:
            return String(localized: "This server doesn't allow new accounts. Turn registration on in its settings, then try again.", comment: "Ente account creation error")
        case .accountExists:
            return String(localized: "This server already has an account with this email. Sign in instead.", comment: "Ente account creation error")
        case .passwordTooShort:
            return String(localized: "Use at least \(EnteSignUp.minimumPasswordLength) characters for your password.", comment: "Ente account creation error. The placeholder is the number of characters.")
        case .passwordsDiffer:
            return String(localized: "The passwords don't match.", comment: "Ente account creation error")
        case .notVerified:
            return String(localized: "The server didn't save the account as expected. Try signing in, or create it again with another email.", comment: "Ente account creation error")
        }
    }
}

/// The keys of a new account, made on this device. Nothing here has been sent anywhere yet.
nonisolated struct EnteNewAccountKeys: Sendable {
    let attributes: EnteNewKeyAttributes
    /// 32 bytes in hex, a format Ente's apps take to recover an account.
    let recoveryKey: String
    let srpUserID: String
    let srpSalt: Data
    let srpVerifier: Data
    let loginKey: Data
}

/// Creates an account the way Ente's own apps do (`rust/crates/accounts/src/signup.rs`), for self-hosted servers. Ente's
/// servers are refused by `EnteAPIClient`.
///
/// A random master key encrypts everything else. The password only protects the master key, through a key derived on
/// this device, and the recovery key protects it too. The server gets them all encrypted.
enum EnteSignUp {

    nonisolated static let minimumPasswordLength = 8

    /// Makes the keys of a new account. This takes a few seconds and a lot of memory.
    @concurrent nonisolated static func generateKeys(password: String) async throws -> EnteNewAccountKeys {
        var masterKey = EnteCrypto.randomBytes(EnteCrypto.keyLength)
        var recoveryKey = EnteCrypto.randomBytes(EnteCrypto.keyLength)
        var keyEncryptionKey: Data
        let kekSalt: Data, opsLimit: UInt64, memLimit: UInt64
        (keyEncryptionKey, kekSalt, opsLimit, memLimit) = try EnteCrypto.deriveNewKeyEncryptionKey(password: password)
        let publicKey: Data
        var secretKey: Data
        (publicKey, secretKey) = try EnteCrypto.generateKeyPair()
        // Only the encrypted keys leave this function, and the login key, which SRP needs.
        defer {
            masterKey.wipe()
            recoveryKey.wipe()
            keyEncryptionKey.wipe()
            secretKey.wipe()
        }

        let encryptedKey = try EnteCrypto.secretBox(masterKey, key: keyEncryptionKey)
        let encryptedSecretKey = try EnteCrypto.secretBox(secretKey, key: masterKey)
        let masterWithRecovery = try EnteCrypto.secretBox(masterKey, key: recoveryKey)
        let recoveryWithMaster = try EnteCrypto.secretBox(recoveryKey, key: masterKey)

        let srpUserID = UUID().uuidString.lowercased()
        let srpSalt = EnteCrypto.randomBytes(16)
        let loginKey = try EnteCrypto.deriveLoginKey(keyEncryptionKey: keyEncryptionKey)
        return EnteNewAccountKeys(
            attributes: EnteNewKeyAttributes(
                kekSalt: kekSalt.base64EncodedString(),
                encryptedKey: encryptedKey.cipherText.base64EncodedString(),
                keyDecryptionNonce: encryptedKey.nonce.base64EncodedString(),
                publicKey: publicKey.base64EncodedString(),
                encryptedSecretKey: encryptedSecretKey.cipherText.base64EncodedString(),
                secretKeyDecryptionNonce: encryptedSecretKey.nonce.base64EncodedString(),
                memLimit: memLimit,
                opsLimit: opsLimit,
                masterKeyEncryptedWithRecoveryKey: masterWithRecovery.cipherText.base64EncodedString(),
                masterKeyDecryptionNonce: masterWithRecovery.nonce.base64EncodedString(),
                recoveryKeyEncryptedWithMasterKey: recoveryWithMaster.cipherText.base64EncodedString(),
                recoveryKeyDecryptionNonce: recoveryWithMaster.nonce.base64EncodedString()),
            recoveryKey: recoveryKey.map { String(format: "%02x", $0) }.joined(),
            srpUserID: srpUserID,
            srpSalt: srpSalt,
            srpVerifier: EnteSRPClient.verifier(identity: srpUserID, password: loginKey, salt: srpSalt),
            loginKey: loginKey)
    }

    /// Sets up SRP, so the password never has to leave the device, and checks the server's proof.
    static func setUpSRP(_ keys: EnteNewAccountKeys, api: EnteAPIClient, token: String) async throws {
        let client = EnteSRPClient(identity: keys.srpUserID, password: keys.loginKey, salt: keys.srpSalt)
        let setup = try await api.setUpSRP(token: token, srpUserID: keys.srpUserID, srpSalt: keys.srpSalt,
                                           srpVerifier: keys.srpVerifier, srpA: client.publicKey)
        let proofs = try client.proofs(serverPublicKey: setup.srpB)
        let srpM2 = try await api.completeSRPSetup(token: token, setupID: setup.setupID, srpM1: proofs.clientProof)
        try EnteSRPClient.verify(serverProof: srpM2, expected: proofs.expectedServerProof)
    }
}
