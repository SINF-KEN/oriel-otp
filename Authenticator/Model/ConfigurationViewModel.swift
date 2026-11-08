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

import SwiftUI
import OSLog
import YubiKit

@Observable class ConfigurationViewModel {

    /// How full the YubiKey's OATH application is.
    struct OATHStorage: Equatable {
        /// The accounts on the YubiKey, nil while it's locked with a password that isn't saved.
        let used: Int?
        let capacity: Int

        var free: Int? { used.map { max(capacity - $0, 0) } }
    }

    var deviceInfo: DeviceInfo? {
        didSet {
            resetDeviceInfoTask?.cancel()
            resetDeviceInfoTask = nil
            if deviceInfo == nil {
                oathStorage = nil
            }
        }
    }
    /// The YubiKey's product name, nil if it couldn't be read.
    private(set) var deviceName: String?
    /// Nil until it's been read, or when the YubiKey's OATH application is turned off.
    var oathStorage: OATHStorage?

    @ObservationIgnored var resetDeviceInfoTask: Task<Void, Never>?
    @ObservationIgnored private var wiredConnectionsTask: Task<Void, Never>?

    init() {
        Logger.allocation.debug("ConfigurationViewModel: init")
    }

    func waitForConnection() {
        Logger.connection.debug("ConfigurationViewModel: waitForConnection")
        wiredConnectionsTask?.cancel()
        wiredConnectionsTask = Task { [weak self] in
            for await connection in ConnectionManager.shared.wiredConnections() {
                guard let self else { return }
                guard let connection else {
                    self.deviceInfo = nil
                    continue
                }
                Logger.connection.debug("ConfigurationViewModel: got wired connection")
                do {
                    try await self.readDevice(connection)
                } catch {
                    Logger.connection.error("ConfigurationviewModel: got error: \(error)")
                }
            }
        }
    }

    func start() {
        resetDeviceInfoTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self.deviceInfo = nil
        }
        waitForConnection()
    }

    func scanNFC() {
        Task {
            do {
                let connection = try await ConnectionManager.shared.anyConnection()
                try await readDevice(connection)
                ConnectionManager.shared.closeNFC(message: String(localized: "Configuration read", comment: "NFC connection stopped message."))
            } catch where error.isNFCCancelledByUser {
                // The user dismissed the NFC sheet.
            } catch {
                Logger.connection.error("ConfigurationviewModel: got error: \(error)")
                ConnectionManager.shared.closeNFC(errorMessage: LocalizedErrorWrapper(error: error).localizedDescription)
            }
        }
    }

    private func readDevice(_ connection: SmartCardConnection) async throws {
        // Reading the name selects applications on the connection, so it comes before the session.
        let deviceName = try? await connection.deviceName
        let deviceInfo = try await connection.managementSession().getDeviceInfo()
        self.deviceName = deviceName
        self.deviceInfo = deviceInfo
        self.oathStorage = await Self.oathStorage(connection: connection, deviceInfo: deviceInfo)
    }

    /// Counts the accounts on the YubiKey. A YubiKey locked with a password is unlocked with the saved one, unless it
    /// was saved behind Face ID or Touch ID, which isn't asked for here.
    private static func oathStorage(connection: SmartCardConnection, deviceInfo: DeviceInfo) async -> OATHStorage? {
        do {
            let deviceId = try? await connection.legacyOATHDeviceId()
            let session = try await connection.oathSession(deviceInfo: deviceInfo)
            let capacity = OATHSession.credentialCapacity(version: await session.version)
            do {
                return OATHStorage(used: try await session.listCredentials().count, capacity: capacity)
            } catch where error.isOATHAuthenticationRequired {
                let preferences = PasswordPreferences()
                guard let deviceId, preferences.useSavedPassword(keyIdentifier: deviceId),
                      let accessKey: Data = try? await SecureStore(secureStoreQueryable: PasswordQueryable(service: "OATH")).getValue(for: deviceId),
                      (try? await session.unlock(accessKey: accessKey)) != nil else {
                    return OATHStorage(used: nil, capacity: capacity)
                }
                return OATHStorage(used: try await session.listCredentials().count, capacity: capacity)
            }
        } catch {
            Logger.connection.error("ConfigurationViewModel: couldn't read the OATH storage: \(error)")
            return nil
        }
    }

    deinit {
        wiredConnectionsTask?.cancel()
        Logger.allocation.debug("ConfigurationViewModel: deinit")
    }
}
