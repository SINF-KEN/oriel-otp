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
import CryptoKit
import BigInt

enum EnteSRPError: Error, Equatable {
    case invalidServerValue
    case serverProofMismatch
}

/// The client side of SRP-6a as Ente's server (github.com/ente-io/go-srp) runs it.
///
/// Ente uses the RFC 5054 4096-bit group with SHA-256, the SRP user id as identity and the login key as
/// password. Two parts differ from RFC 5054 and are what Ente's Rust and Dart clients do:
/// - M1 = H(PAD(A) | PAD(B) | PAD(S)) and K = H(PAD(S))
/// - M2 = H(PAD(A) | M1 | K)
/// Values on the wire are big-endian and A, B and S are padded to the 512 byte group size.
nonisolated struct EnteSRPClient {

    static let groupSize = 512

    static let N = BigUInt(
        "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74" +
        "020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F1437" +
        "4FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED" +
        "EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF05" +
        "98DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB" +
        "9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B" +
        "E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF695581718" +
        "3995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D04507A33" +
        "A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7" +
        "ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864" +
        "D87602733EC86A64521F2B18177B200CBBE117577A615D6C770988C0BAD946E2" +
        "08E24FA074E5AB3143DB5BFCE0FD108E4B82D120A92108011A723C12A787E6D7" +
        "88719A10BDBA5B2699C327186AF4E23C1A946834B6150BDA2583E9CA2AD44CE8" +
        "DBBBC2DB04DE8EF92E8EFC141FBECAA6287C59474E6BC05D99B2964FA090C3A2" +
        "233BA186515BE7ED1F612970CEE2D7AFB81BDD762170481CD0069127D5B05AA9" +
        "93B4EA988D8FDDC186FFB7DC90A6C08F4DF435C934063199FFFFFFFFFFFFFFFF",
        radix: 16)!

    static let g = BigUInt(5)

    static var primeBytes: Data { N.serialize() }

    // k = H(N | PAD(g))
    static let k = BigUInt(hash(N.serialize(), pad(g.serialize())))

    private let identity: Data
    private let password: Data
    private let salt: Data
    private let a: BigUInt
    private let A: BigUInt

    /// - Parameter privateKey: Only set by tests, otherwise 64 random bytes are used like Ente's clients do.
    init(identity: String, password: Data, salt: Data, privateKey: Data? = nil) {
        self.identity = Data(identity.utf8)
        self.password = password
        self.salt = salt
        var a = BigUInt(privateKey ?? EnteCrypto.randomBytes(64))
        if a.isZero { a = 1 }
        self.a = a
        self.A = Self.g.power(a, modulus: Self.N)
    }

    /// A padded to the group size, sent as `srpA`.
    var publicKey: Data { Self.pad(A.serialize()) }

    /// Computes the client proof M1 and the proof the server must answer with. Pass the server's `srpB`.
    func proofs(serverPublicKey: Data) throws -> (clientProof: Data, expectedServerProof: Data) {
        guard serverPublicKey.count <= Self.groupSize else { throw EnteSRPError.invalidServerValue }
        let B = BigUInt(serverPublicKey)
        // The SRP-6a safeguard: abort if B % N is zero.
        guard !(B % Self.N).isZero else { throw EnteSRPError.invalidServerValue }

        let paddedA = publicKey
        let paddedB = Self.pad(B.serialize())
        let u = BigUInt(Self.hash(paddedA, paddedB))
        guard !u.isZero else { throw EnteSRPError.invalidServerValue }

        // x = H(salt | H(I | ":" | P))
        let x = BigUInt(Self.hash(salt, Self.hash(identity, Data(":".utf8), password)))
        let N = Self.N
        let gx = Self.g.power(x, modulus: N)
        let kgx = (Self.k * gx) % N
        // S = (B - k * g^x) ^ (a + u * x) % N, adding N to keep the base positive.
        let base = (B % N + N - kgx) % N
        let S = base.power(a + u * x, modulus: N)

        let paddedS = Self.pad(S.serialize())
        let clientProof = Self.hash(paddedA, paddedB, paddedS)
        let K = Self.hash(paddedS)
        let serverProof = Self.hash(paddedA, clientProof, K)
        return (clientProof, serverProof)
    }

    /// Verifies the server's `srpM2` in constant time.
    static func verify(serverProof: Data, expected: Data) throws {
        guard serverProof.count == expected.count else { throw EnteSRPError.serverProofMismatch }
        let difference = zip(serverProof, expected).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) }
        guard difference == 0 else { throw EnteSRPError.serverProofMismatch }
    }

    static func pad(_ data: Data) -> Data {
        guard data.count < groupSize else { return data }
        return Data(count: groupSize - data.count) + data
    }

    private static func hash(_ parts: Data...) -> Data {
        var hasher = SHA256()
        parts.forEach { hasher.update(data: $0) }
        return Data(hasher.finalize())
    }
}
