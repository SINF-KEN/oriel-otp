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
import OSLog
import Observation
import YubiKit

@Observable class FIDOResetViewModel {

    var state: ResetState = .ready
    
    enum ResetState: Equatable {
        case ready, success, error(Error)
        
        static func == (lhs: FIDOResetViewModel.ResetState, rhs: FIDOResetViewModel.ResetState) -> Bool {
            switch (lhs, rhs) {
            case (.ready, .ready):
                return true
            case (.success, .success):
                return true
            case (.error(_), .error(_)):
                return true
            default:
                return false
            }
        }
        
        func isError() -> Bool {
            switch self {
            case (.error(_)):
                return true
            default:
                return false
            }
        }
    }
    
    @ObservationIgnored private var resetTask: Task<Void, Never>?

    func reset() {
        resetTask = Task {
            do {
                let connection = try await ConnectionManager.shared.anyConnection()
                switch connection {
                case is USBSmartCardConnection:
                    state = .error(FidoViewModelError.usbNotSupported)
                #if os(iOS)
                case let connection as NFCSmartCardConnection:
                    await resetNFC(connection: connection)
                #endif
                default:
                    state = .error(String(localized: "Unknown error"))
                }
            } catch where error.isNFCCancelledByUser || error is CancellationError {
                // The user dismissed the NFC sheet or cancelled the reset.
            } catch {
                state = .error(LocalizedErrorWrapper(error: error))
            }
        }
    }

    func cancelReset() {
        resetTask?.cancel()
    }

    init() {
        Logger.allocation.debug("FIDOresetViewModel: init")
    }
    
    deinit {
        Logger.allocation.debug("FIDOresetViewModel: deinit")
    }
}


#if os(iOS)
extension FIDOResetViewModel {
    private func resetNFC(connection: NFCSmartCardConnection) async {
        do {
            let session = try await connection.fido2Session()
            try await session.reset().value
            let message = String(localized: "Reset FIDO application", comment: "FIDO reset NFC confirmation message")
            ConnectionManager.shared.closeNFC(message: message)
            state = .success
        } catch {
            let localizedError = LocalizedErrorWrapper(error: error)
            ConnectionManager.shared.closeNFC(errorMessage: localizedError.localizedDescription)
            state = .error(localizedError)
        }
    }
}
#endif

