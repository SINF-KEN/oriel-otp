/*
 * Copyright (C) Yubico.
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
import UIKit
import YubiKit

enum OATHSessionError: Error, LocalizedError, Equatable {

    case credentialAlreadyPresent(issuer: String, accountName: String)
    case credentialNotFound
    case otpEnabledError
    case oathDisabledError
    case connectionCancelled
    case invalidDeviceInfo
    case nfcNotSupported
    case fipsKeyWithoutPassword
    /// The YubiKey filled up while adding accounts. Holds the names of the accounts that weren't added.
    case storageFull(notAdded: [String])

    public var errorDescription: String? {
        switch self {
        case .credentialAlreadyPresent(let issuer, let accountName):
            let name = issuer.isEmpty ? accountName : "\(issuer), \(accountName)"
            return String(localized: "There's already an account named \(name) on this YubiKey.", comment: "OATH add account duplicate error. The placeholder is the issuer and account name.")
        case .credentialNotFound:
            return String(localized: "The account could not be found on the YubiKey.", comment: "OATH error when an account is missing after renaming it")
        case .otpEnabledError:
            return String(localized: "Yubico OTP enabled", comment: "OATH otp enabled error message")
        case .oathDisabledError:
            return String(localized: "The OATH application is disabled or not supported on this YubiKey.", comment: "OATH disabled error message")
        case .connectionCancelled:
            return String(localized: "Connection cancelled by user", comment: "Internal error message not to be displayed to the user.")
        case .invalidDeviceInfo:
            return String(localized: "Invalid device info received from YubiKey", comment: "Internal error message not to be displayed to the user.")
        case .nfcNotSupported:
            return String(localized: "NFC not supported on this device", comment: "Internal error message not to be displayed to the user.")
        case .fipsKeyWithoutPassword:
            return String(localized: "To add an account to a FIPS key, you must first set a password for the OATH application.", comment: "Error message when trying to add and OATH account to a FIPS key without a password.")
        case .storageFull(let notAdded):
            let names = notAdded.formatted(.list(type: .and))
            return String(localized: "The YubiKey is full. These accounts weren't added: \(names).", comment: "Import error. The placeholder is a list of account names.")
        }
    }
}

/// Hands out OATH sessions on the wired or NFC connection.
///
/// The current session is reused until its connection closes, so the OATH application stays unlocked.
final class OATHSessionHandler {

    static let shared = OATHSessionHandler()

    private var currentSession: OATHSession?

    /// Yields a new session each time a wired YubiKey is inserted. Throws if the YubiKey can't be used.
    func wiredSessions() -> AsyncThrowingStream<OATHSession, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                for await connection in ConnectionManager.shared.wiredConnections() {
                    guard let connection else { continue }
                    do {
                        continuation.yield(try await self.wiredSession(connection: connection))
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                }
                continuation.finish(throwing: OATHSessionError.connectionCancelled)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func anySession() async throws -> OATHSession {
        if let currentSession {
            return currentSession
        } else if let connection = ConnectionManager.shared.wiredConnection {
            return try await makeSession(connection: connection, type: .wired, deviceInfo: await connection.deviceInfo())
        } else {
            return try await nfcSession()
        }
    }

    func nfcSession() async throws -> OATHSession {
        guard DeviceCapabilities.supportsNFC else { throw OATHSessionError.nfcNotSupported }
        let connection = try await ConnectionManager.shared.nfcConnection()
        return try await makeSession(connection: connection, type: .nfc, deviceInfo: await connection.deviceInfo())
    }

    private func wiredSession(connection: SmartCardConnection) async throws -> OATHSession {
        let deviceInfo = await connection.deviceInfo()
        // Yubico OTP over USB makes the YubiKey act as a keyboard, which hides the on-screen keyboard on iPhone.
        if connection is USBSmartCardConnection && UIDevice.current.userInterfaceIdiom == .phone, let deviceInfo,
           deviceInfo.config.isApplicationEnabled(.otp, over: .usb) && !SettingsConfig.isOTPOverUSBIgnored(deviceId: deviceInfo.serialNumber) {
            throw OATHSessionError.otpEnabledError
        }
        do {
            return try await makeSession(connection: connection, type: .wired, deviceInfo: deviceInfo)
        } catch where error.isApplicationNotSupported {
            throw OATHSessionError.oathDisabledError
        }
    }

    private func makeSession(connection: SmartCardConnection, type: OATHSession.ConnectionType, deviceInfo: DeviceInfo?) async throws -> OATHSession {
        let deviceId = try? await connection.legacyOATHDeviceId()
        let session = try await connection.oathSession(deviceInfo: deviceInfo)
        guard let deviceId else { throw OATHSessionError.invalidDeviceInfo }
        let oathSession = OATHSession(session: session,
                                      connection: connection,
                                      type: type,
                                      version: await session.version,
                                      deviceId: deviceId,
                                      isFipsKey: deviceInfo?.isFIPSCapable(FIPSCapability.oath) ?? false)
        currentSession = oathSession
        Task {
            _ = await ConnectionManager.shared.waitUntilClosed(connection)
            if self.currentSession === oathSession {
                self.currentSession = nil
            }
        }
        return oathSession
    }
}

final class OATHSession: Sendable {

    enum ConnectionType: Sendable {
        case nfc
        case wired
    }

    enum CredentialType: Sendable {
        case totp, hotp
    }

    struct Credential: Equatable, Sendable {
        static func == (lhs: OATHSession.Credential, rhs: OATHSession.Credential) -> Bool {
            return lhs.id == rhs.id
        }
        let type: CredentialType
        var label: String? {
            if let issuer {
                return "\(issuer):\(accountName)"
            } else {
                return accountName
            }
        }
        var issuer: String?
        var accountName: String
        let period: UInt
        let requiresTouch: Bool
        var isSteam: Bool {
            type == .totp && issuer?.lowercased() == "steam"
        }
        fileprivate let yubiKitCredential: YubiKitOATHSession.Credential

        fileprivate init(yubiKitCredential: YubiKitOATHSession.Credential, requiresTouch: Bool? = nil) {
            switch yubiKitCredential.type {
            case .totp(let period):
                self.type = .totp
                self.period = UInt(period)
            case .hotp:
                self.type = .hotp
                self.period = 0
            }
            self.issuer = yubiKitCredential.issuer
            self.accountName = yubiKitCredential.name
            self.requiresTouch = requiresTouch ?? yubiKitCredential.requiresTouch
            self.yubiKitCredential = yubiKitCredential
        }
    }

    struct OTP: Equatable {
        let code: String
        let validity: DateInterval
    }

    private let session: YubiKitOATHSession
    private let connection: SmartCardConnection
    let type: ConnectionType
    let version: Version
    /// Identifies the YubiKey, saved passwords are stored under it.
    let deviceId: String
    /// The key is FIPS capable for OATH, which requires a password before accounts can be added.
    let isFipsKey: Bool

    fileprivate init(session: YubiKitOATHSession, connection: SmartCardConnection, type: ConnectionType, version: Version, deviceId: String, isFipsKey: Bool) {
        self.session = session
        self.connection = connection
        self.type = type
        self.version = version
        self.deviceId = deviceId
        self.isFipsKey = isFipsKey
    }

    func sessionDidEnd() async -> Error? {
        await ConnectionManager.shared.waitUntilClosed(connection)
    }

    func addCredential(template: YubiKitOATHSession.CredentialTemplate, requiresTouch: Bool) async throws {
        let credentials = try await session.listCredentials()
        let key = template.identifier
        let keys = credentials.map { String(data: $0.id, encoding: .utf8) }
        guard !keys.contains(key) else {
            ConnectionManager.shared.closeNFC(errorMessage: String(localized: "Duplicate accounts!", comment: "OATH add credential duplicate accounts error"))
            throw OATHSessionError.credentialAlreadyPresent(issuer: template.issuer ?? "", accountName: template.name)
        }

        var template = template
        template.requiresTouch = requiresTouch
        do {
            try await session.addCredential(template: template)
        } catch {
            // If yubikey is a fips enabled key a password has to be set before you can add a new account
            if isFipsKey, error.statusCode == 0x6985 {
                throw OATHSessionError.fipsKeyWithoutPassword
            }
            throw error
        }
    }

    /// How many accounts the OATH application can hold. Firmware 5.7 doubled the storage, and the
    /// YubiKey NEO, whose OATH application reports a version below 4, has room for fewer.
    /// The YubiKey has the final say: adding still stops if it reports that it is full.
    static func credentialCapacity(version: Version) -> Int {
        if version >= Version("5.7.0")! {
            return 64
        } else if version >= Version("4.0.0")! {
            return 32
        } else {
            return 28
        }
    }

    struct AddCredentialsResult {
        var added: [YubiKitOATHSession.CredentialTemplate] = []
        var alreadyPresent: [YubiKitOATHSession.CredentialTemplate] = []
        /// The templates that weren't added because adding stopped early.
        var notAdded: [YubiKitOATHSession.CredentialTemplate] = []
        /// Set when adding stopped early, e.g. because the YubiKey is full.
        var error: Error?
    }

    /// Adds several credentials, listing the credentials on the YubiKey only once.
    /// Credentials with the same name as one on the YubiKey are skipped and adding stops at the first failure.
    func addCredentials(templates: [YubiKitOATHSession.CredentialTemplate], requiresTouch: Bool) async throws -> AddCredentialsResult {
        let credentials = try await session.listCredentials()
        var keys = Set(credentials.compactMap { String(data: $0.id, encoding: .utf8) })
        var result = AddCredentialsResult()
        for (index, template) in templates.enumerated() {
            guard keys.insert(template.identifier).inserted else {
                result.alreadyPresent.append(template)
                continue
            }
            var template = template
            template.requiresTouch = requiresTouch
            do {
                try await session.addCredential(template: template)
                result.added.append(template)
            } catch {
                // If yubikey is a fips enabled key a password has to be set before you can add a new account
                if isFipsKey, error.statusCode == 0x6985 {
                    throw OATHSessionError.fipsKeyWithoutPassword
                }
                result.error = error
                result.notAdded = Array(templates[index...])
                break
            }
        }
        return result
    }

    func deleteCredential(_ credential: Credential) async throws {
        try await session.deleteCredential(credential.yubiKitCredential)
    }

    /// Renames the credential and returns it with its new name.
    func renameCredential(_ credential: Credential, issuer: String, accountName: String) async throws -> Credential {
        let newIssuer = issuer.isEmpty ? nil : issuer
        try await session.renameCredential(credential.yubiKitCredential, newName: accountName, newIssuer: newIssuer)
        let key = OATHCredentialId.key(accountName: accountName, issuer: newIssuer, period: credential.period, isTOTP: credential.type == .totp)
        guard let renamed = try await session.listCredentials().first(where: { $0.id == Data(key.utf8) }) else {
            throw OATHSessionError.credentialNotFound
        }
        return Credential(yubiKitCredential: renamed, requiresTouch: credential.requiresTouch)
    }

    func list() async throws -> [Credential] {
        try await session.listCredentials().map { Credential(yubiKitCredential: $0) }
    }

    func calculateAll(timestamp: Date = Date().addingTimeInterval(10)) async throws -> [(Credential, OTP?)] {
        try await session.calculateCredentialCodes(timestamp: timestamp).map { (Credential(yubiKitCredential: $0), $1?.otp) }
    }

    func calculate(credential: Credential, timestamp: Date = Date().addingTimeInterval(10)) async throws -> OTP {
        if credential.isSteam {
            let (code, validity) = try await session.calculateSteamTOTP(credential: credential.yubiKitCredential)
            return OTP(code: code, validity: validity)
        } else {
            return try await session.calculateCredentialCode(for: credential.yubiKitCredential, timestamp: timestamp).otp
        }
    }

    func unlock(password: String) async throws {
        try await session.unlock(password: password)
    }

    /// Unlocks with the password and returns the access key derived from it.
    func unlock(withPassword password: String) async throws -> Data {
        let accessKey = try await session.deriveAccessKey(from: password)
        try await session.unlock(accessKey: accessKey)
        return accessKey
    }

    func unlock(withAccessKey accessKey: Data) async throws {
        try await session.unlock(accessKey: accessKey)
    }

    func endNFC(message: String? = nil) {
        ConnectionManager.shared.closeNFC(message: message)
    }
}
