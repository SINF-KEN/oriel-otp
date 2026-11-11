/*
 * Copyright (C) 2022 Yubico.
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
import Observation
import YubiKit

enum FidoViewModelError: Error, LocalizedError {
    
    case usbNotSupported, locked, pinsDoNotMatch, severalKeys, fidoNotFound
    
    public var errorDescription: String? {
        switch self {
        case .pinsDoNotMatch:
            return String(localized: "PINs don't match")
        case .usbNotSupported:
            return String(localized: "FIDO management over USB-C is not supported by iOS. Use NFC instead, or manage FIDO on a computer.")
        case .locked:
            return String(localized: "PIN is permanently blocked. Factory reset FIDO application to continue.")
        case .severalKeys:
            return String(localized: "More than one YubiKey is connected. Unplug the others to manage FIDO.")
        case .fidoNotFound:
            return String(localized: "Couldn't reach the FIDO application of this YubiKey. It may be turned off over USB.")
        }
    }
}

@Observable class FIDOPINViewModel {
    
    var state: PINState = .unknown
    var isProcessing: Bool = false
    var pincomplexity: Bool = false
    var minPinLength: UInt = 4
    
    enum PINState: Equatable {
        
        case unknown, notSet, set, error(Error), keyRemoved, didSet, didChange
        
        static func == (lhs: FIDOPINViewModel.PINState, rhs: FIDOPINViewModel.PINState) -> Bool {
            switch (lhs, rhs) {
            case (.unknown, .unknown):
                return true
            case (.notSet, .notSet):
                return true
            case (.set, .set):
                return true
            case (.error(_), .error(_)):
                return true
            case (.keyRemoved, .keyRemoved):
                return true
            case (.didSet, .didSet):
                return true
            case (.didChange, .didChange):
                return true
            default:
                return false
            }
        }
        
        func isBlocked() -> Bool {
            if case .pinAuthBlocked = ctapError { return true }
            return false
        }

        func isPermanentlyBlocked() -> Bool {
            if case .pinBlocked = ctapError { return true }
            return false
        }

        func isFatalError() -> Bool {
            guard isError() else { return false }
            switch ctapError {
            case .pinAuthInvalid, .pinInvalid:
                return false
            default:
                return true
            }
        }

        private func isError() -> Bool {
            switch self {
            case .error(_):
                return true
            default:
                return false
            }
        }

        private var ctapError: CTAP2.Error? {
            switch self {
            case .error(let error):
                return error.ctapError
            default:
                return nil
            }
        }
    }

    @ObservationIgnored private var didLoad = false

    /// Reads the PIN state from the YubiKey. Called by the view rather than from `init` since
    /// SwiftUI may create the model several times before the view appears.
    func load() {
        guard !didLoad else { return }
        didLoad = true
        Task {
            do {
                let connection = try await ConnectionManager.shared.anyConnection()
                #if os(iOS)
                guard !(connection is USBSmartCardConnection) else {
                    state = .error(FidoViewModelError.usbNotSupported)
                    return
                }
                #endif
                watchForRemoval(of: connection)
                let deviceInfo = try await connection.managementSession().getDeviceInfo()
                pincomplexity = deviceInfo.pinComplexity
                try await withFIDO2Session(on: connection, deviceInfo: deviceInfo) { session in
                    let info = try await session.getInfo()
                    minPinLength = info.minPinLength ?? 4
                    guard let pinIsSet = info.options.clientPin else {
                        state = .unknown
                        return
                    }
                    if !pinIsSet {
                        state = .notSet
                        ConnectionManager.shared.closeNFC(message: String(localized: "PIN state read"))
                    } else {
                        let retries = try await session.getPinRetries().retries
                        if retries <= 0 {
                            ConnectionManager.shared.closeNFC(errorMessage: FidoViewModelError.locked.localizedDescription)
                            state = .error(FidoViewModelError.locked)
                        } else {
                            ConnectionManager.shared.closeNFC(message: String(localized: "PIN state read"))
                            state = .set
                        }
                    }
                }
            } catch where error.isNFCCancelledByUser {
                // The user dismissed the NFC sheet.
            } catch {
                let error = LocalizedErrorWrapper(error: error)
                ConnectionManager.shared.closeNFC(errorMessage: error.localizedDescription)
                state = .error(error)
            }
        }
    }

    /// Runs `body` with a FIDO2 session on the connection's YubiKey. On the Mac a USB YubiKey's FIDO
    /// application is reached over the key's HID interface, which is closed when `body` returns.
    /// - Parameter deviceInfo: The key's device info, if already read.
    private func withFIDO2Session<T>(on connection: SmartCardConnection,
                                     deviceInfo: DeviceInfo? = nil,
                                     _ body: (CTAP2.Session) async throws -> T) async throws -> T {
        #if os(macOS)
        if connection is USBSmartCardConnection {
            let deviceInfo = if let deviceInfo { deviceInfo } else { await connection.deviceInfo() }
            let fidoConnection = try await ConnectionManager.shared.fidoConnection(matching: deviceInfo)
            do {
                let result = try await body(try await CTAP2.Session.makeSession(connection: fidoConnection))
                await fidoConnection.close(error: nil)
                return result
            } catch {
                await fidoConnection.close(error: nil)
                throw error
            }
        }
        #endif
        return try await body(try await connection.fido2Session())
    }

    private func watchForRemoval(of connection: SmartCardConnection) {
        Task { [weak self] in
            let error = await ConnectionManager.shared.waitUntilClosed(connection)
            if connection.isNFC && error == nil { return }
            self?.state = .keyRemoved
        }
    }

    func setPIN(_ pin: String) {
        self.isProcessing = true
        self.state = .unknown
        Task {
            do {
                try await withFIDO2Session(on: ConnectionManager.shared.anyConnection()) { session in
                    try await session.setPin(pin)
                }
                self.state = .didSet
                ConnectionManager.shared.closeNFC(message: String(localized: "PIN has been set"))
            } catch {
                self.state = .error(error)
                ConnectionManager.shared.closeNFC(errorMessage: LocalizedErrorWrapper(error: error).localizedDescription)
            }
            self.isProcessing = false
        }
    }

    func changePIN(old oldPIN: String, new newPIN: String) {
        self.isProcessing = true
        self.state = .unknown
        Task {
            do {
                try await withFIDO2Session(on: ConnectionManager.shared.anyConnection()) { session in
                    try await session.changePin(from: oldPIN, to: newPIN)
                }
                self.state = .didChange
                ConnectionManager.shared.closeNFC(message: String(localized: "PIN has been changed"))
            } catch {
                self.state = .error(error)
                ConnectionManager.shared.closeNFC(errorMessage: LocalizedErrorWrapper(error: error).localizedDescription)
            }
            self.isProcessing = false
        }
    }
}
