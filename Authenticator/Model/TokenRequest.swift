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
import Security

/// What the token extension asks the app to do with the YubiKey.
nonisolated enum OperationType: String, Sendable {
    case signData
    case decryptData
}

/// The type of the key in a PIV slot, as the token extension sends it.
nonisolated enum TokenKeyType: UInt8, Sendable {
    case rsa1024 = 0x06
    case rsa2048 = 0x07
    case eccp256 = 0x11
    case eccp384 = 0x14

    /// The type of a key in the token's keychain, nil for one a YubiKey's PIV slot can't hold.
    init?(keyType: String, keySizeInBits: Int) {
        let rsa = kSecAttrKeyTypeRSA as String
        let ec = kSecAttrKeyTypeECSECPrimeRandom as String
        switch (keyType, keySizeInBits) {
        case (rsa, 1024): self = .rsa1024
        case (rsa, 2048): self = .rsa2048
        case (ec, 256): self = .eccp256
        case (ec, 384): self = .eccp384
        default: return nil
        }
    }
}

/// A request from the token extension, sent to the app in the user info of a notification. Both sides read and write
/// it here, so they can't disagree on the keys.
nonisolated struct TokenRequest: Sendable, Equatable {
    let operation: OperationType
    let data: Data
    /// The token object ID of the certificate, see `SecCertificate.tokenObjectId()`.
    let objectID: String
    let keyType: TokenKeyType
    let algorithm: SecKeyAlgorithm
    /// The name the answer is filed under, see `TokenResponseStore.requestIDKey`.
    let requestID: String

    private enum Key {
        static let operation = "operationType"
        static let data = "data"
        static let objectID = "keyObjectID"
        static let keyType = "keyType"
        static let algorithm = "algorithm"
    }

    init(operation: OperationType, data: Data, objectID: String, keyType: TokenKeyType, algorithm: SecKeyAlgorithm, requestID: String) {
        self.operation = operation
        self.data = data
        self.objectID = objectID
        self.keyType = keyType
        self.algorithm = algorithm
        self.requestID = requestID
    }

    /// Nil when anything is missing or unknown, e.g. a notification from an older version without a request ID.
    init?(userInfo: [AnyHashable: Any]) {
        guard let operation = (userInfo[Key.operation] as? String).flatMap(OperationType.init(rawValue:)),
            let data = userInfo[Key.data] as? Data,
            let objectID = userInfo[Key.objectID] as? String,
            // A notification's user info comes back as a property list, where the UInt8 may become another integer.
            let rawKeyType = (userInfo[Key.keyType] as? UInt8) ?? (userInfo[Key.keyType] as? Int).flatMap(UInt8.init(exactly:)),
            let keyType = TokenKeyType(rawValue: rawKeyType),
            let algorithm = (userInfo[Key.algorithm] as? String).map({ SecKeyAlgorithm(rawValue: $0 as CFString) }),
            let requestID = userInfo[TokenResponseStore.requestIDKey] as? String
        else { return nil }
        self.init(operation: operation, data: data, objectID: objectID, keyType: keyType, algorithm: algorithm, requestID: requestID)
    }

    var userInfo: [AnyHashable: Any] {
        [
            Key.operation: operation.rawValue,
            Key.data: data,
            Key.objectID: objectID,
            Key.keyType: keyType.rawValue,
            Key.algorithm: algorithm.rawValue as String,
            TokenResponseStore.requestIDKey: requestID
        ]
    }
}
