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

import CryptoKit
import Foundation
import Observation
import SwiftUI
import YubiKit

/// A YubiKey 5C NFC that lives in memory, so the app can be used in the simulator without hardware.
///
/// It answers the OATH and Management APDUs the way firmware 5.7.1 does, so YubiKit and every OATH screen run
/// unchanged: listing and calculating codes, touch, adding, renaming and deleting accounts, passwords and reset.
/// PIV, FIDO and Yubico OTP aren't simulated and report that the application isn't supported.
///
/// The accounts and the password are kept in UserDefaults, so they survive unplugging and relaunching.
/// Plug and unplug it from the main screen's overflow menu.
@MainActor @Observable final class SimulatedYubiKey {

    static let shared = SimulatedYubiKey()

    /// Always in the simulator. On the Mac only when launched with `-SimulatedYubiKey YES`, so debug builds still
    /// use a real YubiKey by default. The fake Ente server comes with it.
    nonisolated static var isEnabled: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return UserDefaults.standard.bool(forKey: "SimulatedYubiKey")
        #endif
    }

    /// Whether the key is plugged in. Unplugging closes the connection like pulling out a real key.
    var isInserted = true {
        didSet {
            guard isInserted != oldValue else { return }
            if isInserted {
                insertionWaiters.forEach { $0.resume() }
                insertionWaiters.removeAll()
            } else if let connection {
                Task { await connection.close(error: nil) }
            }
        }
    }

    @ObservationIgnored private var insertionWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var connection: SimulatedYubiKeyConnection?
    @ObservationIgnored let storage = SimulatedYubiKeyStorage()

    /// Waits until the key is plugged in and connects to it. Used by the connection manager's wired loop.
    nonisolated static func nextConnection() async -> SmartCardConnection {
        await shared.nextConnection()
    }

    private func nextConnection() async -> SmartCardConnection {
        if !isInserted {
            await withCheckedContinuation { insertionWaiters.append($0) }
        }
        let connection = SimulatedYubiKeyConnection(storage: storage)
        self.connection = connection
        return connection
    }

    /// Unplugs the key, erases it back to the demo accounts and plugs it in again.
    func restoreDemoAccounts() {
        isInserted = false
        storage.restoreDemoAccounts()
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            isInserted = true
        }
    }
}

/// Plug, unplug and reset the simulated YubiKey, shown in the main screen's overflow menu.
struct SimulatedYubiKeyMenu: View {
    @Bindable private var yubiKey = SimulatedYubiKey.shared

    var body: some View {
        Menu {
            Toggle("Plugged in", systemImage: "cable.connector", isOn: $yubiKey.isInserted)
            Button("Restore demo accounts", systemImage: "arrow.counterclockwise") {
                yubiKey.restoreDemoAccounts()
            }
        } label: {
            Label("Simulated YubiKey", systemImage: "hammer")
        }
    }
}

// MARK: - Storage

/// What the simulated key has stored, kept in UserDefaults.
nonisolated final class SimulatedYubiKeyStorage: @unchecked Sendable {

    struct Credential: Codable {
        /// The credential id: "issuer:account", prefixed with "period/" when the period isn't 30 seconds.
        var name: Data
        /// The type (0x10 HOTP, 0x20 TOTP) or'ed with the hash algorithm (0x01 SHA-1, 0x02 SHA-256, 0x03 SHA-512).
        var typeAndAlgorithm: UInt8
        var digits: UInt8
        var secret: Data
        var requiresTouch: Bool
        var counter: UInt32

        var isHOTP: Bool { typeAndAlgorithm & 0xf0 == 0x10 }
    }

    struct State: Codable {
        var salt: Data
        var accessKey: Data?
        var credentials: [Credential]
        var serialNumber: UInt32
        var usbEnabled: UInt16
        var nfcEnabled: UInt16
    }

    private static let defaultsKey = "SimulatedYubiKey"
    private let lock = NSLock()
    private var state: State

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let state = try? JSONDecoder().decode(State.self, from: data) {
            self.state = state
        } else {
            state = Self.demoState()
            save()
        }
    }

    func withState<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        let result = body(&state)
        save()
        return result
    }

    func restoreDemoAccounts() {
        withState { $0 = Self.demoState() }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    // Each demo account's secret is the first 10 bytes of the SHA-256 of its name, so the accounts show different
    // codes. The salt and serial number are fixed so the README screenshots are the same on every run.
    private static func demoState() -> State {
        func credential(_ name: String, type: UInt8 = 0x20, algorithm: UInt8 = 0x01, digits: UInt8 = 6, touch: Bool = false) -> Credential {
            let secret = Data(SHA256.hash(data: Data(name.utf8)).prefix(10))
            return Credential(name: Data(name.utf8), typeAndAlgorithm: type | algorithm, digits: digits, secret: secret, requiresTouch: touch, counter: 0)
        }
        return State(
            salt: Data([0x0d, 0xe0, 0x0d, 0xe0, 0x0d, 0xe0, 0x0d, 0xe0]),
            accessKey: nil,
            credentials: [
                credential("GitHub:alice@example.com"),
                credential("Google:alice@example.com"),
                credential("Microsoft:alice@outlook.com", digits: 8),
                credential("AWS:admin", touch: true),
                credential("60/Bank:alice", algorithm: 0x02),
                credential("Steam:alice"),
                credential("Example HOTP:alice", type: 0x10),
                credential("Server root"),
            ],
            serialNumber: 31_415_926,
            usbEnabled: 0x023b,
            nfcEnabled: 0x023b
        )
    }
}

// MARK: - Connection

/// One connection to the simulated key, open until the key is unplugged.
actor SimulatedYubiKeyConnection: SmartCardConnection {

    private enum SelectedApplication { case none, oath, management }

    private let storage: SimulatedYubiKeyStorage
    private var selected = SelectedApplication.none
    private var isUnlocked = false
    private var challenge = Data()
    private var isClosed = false
    private var closeError: Error?
    private var closeWaiters: [CheckedContinuation<Error?, Never>] = []

    private static let version: [UInt8] = [5, 7, 1]
    private static let oathAID = Data([0xa0, 0x00, 0x00, 0x05, 0x27, 0x21, 0x01])
    private static let managementAID = Data([0xa0, 0x00, 0x00, 0x05, 0x27, 0x47, 0x11, 0x17])

    init(storage: SimulatedYubiKeyStorage) {
        self.storage = storage
    }

    init() async throws(SmartCardConnectionError) {
        self.storage = SimulatedYubiKeyStorage()
    }

    static func makeConnection() async throws(SmartCardConnectionError) -> SimulatedYubiKeyConnection {
        try await SimulatedYubiKeyConnection()
    }

    func close(error: Error?) {
        guard !isClosed else { return }
        isClosed = true
        closeError = error
        closeWaiters.forEach { $0.resume(returning: error) }
        closeWaiters.removeAll()
    }

    func waitUntilClosed() async -> Error? {
        if isClosed { return closeError }
        return await withCheckedContinuation { closeWaiters.append($0) }
    }

    func send(data: Data) async throws(SmartCardConnectionError) -> Data {
        guard !isClosed else { throw .connectionLost }
        let apdu = Data(data)
        guard apdu.count >= 4 else { return Status.wrongLength }
        let ins = apdu[1], p1 = apdu[2], p2 = apdu[3]
        let body = Self.commandData(of: apdu)

        if ins == 0xa4 && p1 == 0x04 {
            return select(aid: body)
        }
        switch selected {
        case .oath: return await oath(ins: ins, p1: p1, p2: p2, data: body)
        case .management: return management(ins: ins, data: body)
        case .none: return Status.fileNotFound
        }
    }

    private static func commandData(of apdu: Data) -> Data {
        guard apdu.count > 5 else { return Data() }
        if apdu[4] == 0x00 && apdu.count > 7 {
            let length = Int(apdu[5]) << 8 | Int(apdu[6])
            return apdu.subdata(in: 7..<min(7 + length, apdu.count))
        }
        let length = Int(apdu[4])
        return apdu.subdata(in: 5..<min(5 + length, apdu.count))
    }

    // MARK: Select

    private func select(aid: Data) -> Data {
        switch aid {
        case Self.oathAID:
            selected = .oath
            let state = storage.withState { $0 }
            var response = TLV.encode(0x79, Data(Self.version)) + TLV.encode(0x71, state.salt)
            if state.accessKey != nil {
                challenge = Data((0..<8).map { _ in UInt8.random(in: 0...255) })
                response += TLV.encode(0x74, challenge) + TLV.encode(0x7b, Data([0x01]))
                isUnlocked = false
            } else {
                isUnlocked = true
            }
            return response + Status.ok
        case Self.managementAID:
            selected = .management
            return Data("Virtual mgmt - FW version \(Self.version.map(String.init).joined(separator: "."))".utf8) + Status.ok
        default:
            selected = .none
            return Status.fileNotFound
        }
    }

    // MARK: OATH

    private func oath(ins: UInt8, p1: UInt8, p2: UInt8, data: Data) async -> Data {
        // Without the password only validate and reset are allowed.
        guard isUnlocked || ins == 0xa3 || ins == 0x04 else { return Status.securityConditionNotSatisfied }
        let tlvs = TLV.decode(data)
        switch ins {
        case 0xa1: return list()
        case 0x01: return put(tlvs)
        case 0x02: return delete(tlvs)
        case 0x05: return rename(tlvs)
        case 0xa2: return await calculate(tlvs, truncated: p2 == 0x01)
        case 0xa4: return calculateAll(tlvs)
        case 0xa3: return validate(tlvs)
        case 0x03: return setCode(tlvs)
        case 0x04:
            guard p1 == 0xde && p2 == 0xad else { return Status.incorrectParameters }
            storage.withState {
                $0.credentials.removeAll()
                $0.accessKey = nil
                // A reset gives the OATH application a new salt, and with it a new device id.
                $0.salt = Data((0..<8).map { _ in UInt8.random(in: 0...255) })
            }
            isUnlocked = true
            return Status.ok
        default:
            return Status.invalidInstruction
        }
    }

    private func list() -> Data {
        let credentials = storage.withState { $0.credentials }
        return credentials.reduce(Data()) { $0 + TLV.encode(0x72, Data([$1.typeAndAlgorithm]) + $1.name) } + Status.ok
    }

    private func put(_ tlvs: [(tag: UInt8, value: Data)]) -> Data {
        guard let name = tlvs.first(where: { $0.tag == 0x71 })?.value,
              let key = tlvs.first(where: { $0.tag == 0x73 })?.value, key.count >= 2 else { return Status.wrongData }
        let counter = tlvs.first(where: { $0.tag == 0x7a })?.value.reduce(UInt32(0)) { $0 << 8 | UInt32($1) } ?? 0
        let requiresTouch = tlvs.first(where: { $0.tag == 0x78 }).map { $0.value.first == 0x02 } ?? false
        let credential = SimulatedYubiKeyStorage.Credential(name: name, typeAndAlgorithm: key[key.startIndex],
                                                             digits: key[key.startIndex + 1], secret: key.dropFirst(2),
                                                             requiresTouch: requiresTouch, counter: counter)
        storage.withState { state in
            // Like the firmware, adding an account with the name of an existing one replaces it.
            if let index = state.credentials.firstIndex(where: { $0.name == name }) {
                state.credentials[index] = credential
            } else {
                state.credentials.append(credential)
            }
        }
        return Status.ok
    }

    private func delete(_ tlvs: [(tag: UInt8, value: Data)]) -> Data {
        guard let name = tlvs.first(where: { $0.tag == 0x71 })?.value else { return Status.wrongData }
        let deleted = storage.withState { state in
            guard let index = state.credentials.firstIndex(where: { $0.name == name }) else { return false }
            state.credentials.remove(at: index)
            return true
        }
        return deleted ? Status.ok : Status.noSuchObject
    }

    private func rename(_ tlvs: [(tag: UInt8, value: Data)]) -> Data {
        let names = tlvs.filter { $0.tag == 0x71 }.map(\.value)
        guard names.count == 2 else { return Status.wrongData }
        return storage.withState { state in
            guard let index = state.credentials.firstIndex(where: { $0.name == names[0] }) else { return Status.noSuchObject }
            guard !state.credentials.contains(where: { $0.name == names[1] }) else { return Status.incorrectParameters }
            state.credentials[index].name = names[1]
            return Status.ok
        }
    }

    private func calculate(_ tlvs: [(tag: UInt8, value: Data)], truncated: Bool) async -> Data {
        guard let name = tlvs.first(where: { $0.tag == 0x71 })?.value,
              var challenge = tlvs.first(where: { $0.tag == 0x74 })?.value else { return Status.wrongData }
        guard let credential = storage.withState({ $0.credentials.first { $0.name == name } }) else { return Status.noSuchObject }
        if credential.requiresTouch {
            // Gives the touch prompt time to show, like waiting for a finger on the key.
            try? await Task.sleep(for: .seconds(1.5))
        }
        if credential.isHOTP {
            let counter = storage.withState { state -> UInt32 in
                guard let index = state.credentials.firstIndex(where: { $0.name == name }) else { return 0 }
                defer { state.credentials[index].counter += 1 }
                return state.credentials[index].counter
            }
            challenge = Data(withUnsafeBytes(of: UInt64(counter).bigEndian, Array.init))
        }
        let hmac = Self.hmac(credential, challenge: challenge)
        if truncated {
            return TLV.encode(0x76, Self.truncatedCode(credential, hmac: hmac)) + Status.ok
        }
        return TLV.encode(0x75, Data([credential.digits]) + hmac) + Status.ok
    }

    private func calculateAll(_ tlvs: [(tag: UInt8, value: Data)]) -> Data {
        guard let challenge = tlvs.first(where: { $0.tag == 0x74 })?.value else { return Status.wrongData }
        let credentials = storage.withState { $0.credentials }
        var response = Data()
        for credential in credentials {
            response += TLV.encode(0x71, credential.name)
            if credential.isHOTP {
                response += TLV.encode(0x77, Data([credential.digits]))
            } else if credential.requiresTouch {
                response += TLV.encode(0x7c, Data([credential.digits]))
            } else {
                response += TLV.encode(0x76, Self.truncatedCode(credential, hmac: Self.hmac(credential, challenge: challenge)))
            }
        }
        return response + Status.ok
    }

    private func validate(_ tlvs: [(tag: UInt8, value: Data)]) -> Data {
        guard let accessKey = storage.withState({ $0.accessKey }) else { return Status.incorrectParameters }
        guard let response = tlvs.first(where: { $0.tag == 0x75 })?.value,
              let clientChallenge = tlvs.first(where: { $0.tag == 0x74 })?.value else { return Status.wrongData }
        guard response == Self.hmacSHA1(key: accessKey, data: challenge) else { return Status.incorrectParameters }
        isUnlocked = true
        return TLV.encode(0x75, Self.hmacSHA1(key: accessKey, data: clientChallenge)) + Status.ok
    }

    private func setCode(_ tlvs: [(tag: UInt8, value: Data)]) -> Data {
        guard let key = tlvs.first(where: { $0.tag == 0x73 })?.value else { return Status.wrongData }
        if key.isEmpty {
            storage.withState { $0.accessKey = nil }
            return Status.ok
        }
        let accessKey = key.dropFirst()
        guard let challenge = tlvs.first(where: { $0.tag == 0x74 })?.value,
              tlvs.first(where: { $0.tag == 0x75 })?.value == Self.hmacSHA1(key: accessKey, data: challenge) else {
            return Status.wrongData
        }
        storage.withState { $0.accessKey = Data(accessKey) }
        return Status.ok
    }

    private static func hmac(_ credential: SimulatedYubiKeyStorage.Credential, challenge: Data) -> Data {
        let key = SymmetricKey(data: credential.secret)
        switch credential.typeAndAlgorithm & 0x0f {
        case 0x02: return Data(HMAC<SHA256>.authenticationCode(for: challenge, using: key))
        case 0x03: return Data(HMAC<SHA512>.authenticationCode(for: challenge, using: key))
        default: return Data(HMAC<Insecure.SHA1>.authenticationCode(for: challenge, using: key))
        }
    }

    private static func hmacSHA1(key: Data, data: Data) -> Data {
        Data(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    /// The digit count followed by the code as a 4 byte big-endian number, already reduced to that many digits.
    private static func truncatedCode(_ credential: SimulatedYubiKeyStorage.Credential, hmac: Data) -> Data {
        let bytes = [UInt8](hmac)
        let offset = Int(bytes[bytes.count - 1] & 0x0f)
        let value = (UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])) & 0x7fff_ffff
        var power: UInt32 = 1
        for _ in 0..<min(credential.digits, 9) { power *= 10 }
        return Data([credential.digits]) + Data(withUnsafeBytes(of: (value % power).bigEndian, Array.init))
    }

    // MARK: Management

    private func management(ins: UInt8, data: Data) -> Data {
        switch ins {
        case 0x1d:
            let state = storage.withState { $0 }
            func uint16(_ value: UInt16) -> Data { Data([UInt8(value >> 8), UInt8(value & 0xff)]) }
            let tlvs = TLV.encode(0x01, uint16(0x023b))
                + TLV.encode(0x02, Data(withUnsafeBytes(of: state.serialNumber.bigEndian, Array.init)))
                + TLV.encode(0x03, uint16(state.usbEnabled))
                + TLV.encode(0x04, Data([0x03]))
                + TLV.encode(0x05, Data(Self.version))
                + TLV.encode(0x0a, Data([0x00]))
                + TLV.encode(0x0d, uint16(0x023b))
                + TLV.encode(0x0e, uint16(state.nfcEnabled))
            return Data([UInt8(tlvs.count)]) + tlvs + Status.ok
        case 0x1c:
            // The OTP toggle writes the enabled applications.
            let tlvs = TLV.decode(data.dropFirst())
            storage.withState { state in
                for (tag, value) in tlvs where value.count == 2 {
                    let mask = UInt16(value[value.startIndex]) << 8 | UInt16(value[value.startIndex + 1])
                    if tag == 0x03 { state.usbEnabled = mask }
                    if tag == 0x0e { state.nfcEnabled = mask }
                }
            }
            return Status.ok
        default:
            return Status.invalidInstruction
        }
    }
}

// MARK: - Helpers

private nonisolated enum Status {
    static let ok = Data([0x90, 0x00])
    static let wrongLength = Data([0x67, 0x00])
    static let securityConditionNotSatisfied = Data([0x69, 0x82])
    static let noSuchObject = Data([0x69, 0x84])
    static let wrongData = Data([0x6a, 0x80])
    static let incorrectParameters = Data([0x6a, 0x80])
    static let fileNotFound = Data([0x6a, 0x82])
    static let invalidInstruction = Data([0x6d, 0x00])
}

/// The simple TLVs the OATH and Management applications use: one byte tags and BER lengths.
private nonisolated enum TLV {

    static func encode(_ tag: UInt8, _ value: Data) -> Data {
        var data = Data([tag])
        switch value.count {
        case ..<0x80: data.append(UInt8(value.count))
        case ..<0x100: data += [0x81, UInt8(value.count)]
        default: data += [0x82, UInt8(value.count >> 8), UInt8(value.count & 0xff)]
        }
        return data + value
    }

    static func decode(_ data: Data) -> [(tag: UInt8, value: Data)] {
        let bytes = [UInt8](data)
        var result: [(tag: UInt8, value: Data)] = []
        var index = 0
        while index < bytes.count {
            let tag = bytes[index]
            index += 1
            // The touch property is a tag followed by a single byte, without a length.
            if tag == 0x78 {
                guard index < bytes.count else { break }
                result.append((tag, Data([bytes[index]])))
                index += 1
                continue
            }
            guard index < bytes.count else { break }
            var length = Int(bytes[index])
            index += 1
            if length == 0x81, index < bytes.count {
                length = Int(bytes[index])
                index += 1
            } else if length == 0x82, index + 1 < bytes.count {
                length = Int(bytes[index]) << 8 | Int(bytes[index + 1])
                index += 2
            }
            guard index + length <= bytes.count else { break }
            result.append((tag, Data(bytes[index..<index + length])))
            index += length
        }
        return result
    }
}

#endif
