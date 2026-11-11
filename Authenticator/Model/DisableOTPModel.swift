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
import OSLog
import Observation
import YubiKit

@Observable class DisableOTPModel {

    var keyIgnored: Bool = false
    var isConfigurationLocked: Bool = false
    var isDisablingOTP: Bool = false
    var error: Error?

    init() {
        Logger.allocation.debug("DisableOTPModel: init")
    }

    deinit {
        Logger.allocation.debug("DisableOTPModel: deinit")
    }

    /// The serial number of the YubiKey the sheet was opened for. Another key connected since is left alone.
    private var serialNumber: UInt?

    func checkConfigurationLocked() {
        Task {
            guard let (_, deviceInfo) = try? await connectedKey() else { return }
            self.isConfigurationLocked = deviceInfo.isConfigLocked
        }
    }

    func disableOTP() {
        guard !isDisablingOTP else { return }
        isDisablingOTP = true
        Task {
            do {
                let (session, deviceInfo) = try await connectedKey()
                try await session.updateDeviceConfig(deviceInfo.config.disable(application: .otp, over: .usb), reboot: true)
            } catch {
                // Also when the key can't be reached, so the button works again once it is back.
                self.error = error
                isDisablingOTP = false
            }
        }
    }

    func ignoreThisKey() {
        Task {
            do {
                let (_, deviceInfo) = try await connectedKey()
                SettingsConfig.registerUSBCDeviceToIgnore(deviceId: deviceInfo.serialNumber)
                self.keyIgnored = true
            } catch {
                self.error = error
            }
        }
    }

    /// The wired YubiKey, if it is the one this sheet was first shown for.
    private func connectedKey() async throws -> (session: Management.Session, deviceInfo: DeviceInfo) {
        guard let connection = ConnectionManager.shared.wiredConnection else { throw OATHSessionError.yubiKeyNotReachable }
        let session: Management.Session
        let deviceInfo: DeviceInfo
        do {
            session = try await connection.managementSession()
            deviceInfo = try await session.getDeviceInfo()
        } catch {
            throw OATHSessionError.yubiKeyNotReachable
        }
        if let serialNumber {
            guard deviceInfo.serialNumber == serialNumber else { throw OATHSessionError.otherYubiKey }
        } else {
            serialNumber = deviceInfo.serialNumber
        }
        return (session, deviceInfo)
    }
}
