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

    var deviceInfo: DeviceInfo? {
        didSet {
            resetDeviceInfoTask?.cancel()
            resetDeviceInfoTask = nil
        }
    }
    /// The YubiKey's product name, nil if it couldn't be read.
    private(set) var deviceName: String?

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
    }

    deinit {
        wiredConnectionsTask?.cancel()
        Logger.allocation.debug("ConfigurationViewModel: deinit")
    }
}
