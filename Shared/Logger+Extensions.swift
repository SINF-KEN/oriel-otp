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

import OSLog

/// The app's loggers, one per category, in every target. The subsystem is the bundle ID of the app or extension that
/// logs.
nonisolated public extension Logger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "OrielOTP"

    static let allocation = Logger(subsystem: subsystem, category: "Allocation")
    static let autoFill = Logger(subsystem: subsystem, category: "AutoFill")
    static let connection = Logger(subsystem: subsystem, category: "Connection")
    static let ctk = Logger(subsystem: subsystem, category: "CTK")
    static let spotlight = Logger(subsystem: subsystem, category: "Spotlight")
    static let system = Logger(subsystem: subsystem, category: "System")

    func yubilog(_ message: String) {
        self.debug("YUBICO_DEBUG: \(message)")
    }
}
