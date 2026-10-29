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

/// The time codes are calculated for and counted down from.
///
/// Debug builds in the simulator can freeze it with the `-DemoDate <seconds since 1970>` launch argument, so the
/// screenshots in the README show the same codes and timers on every run.
nonisolated enum AppClock {

    static var now: Date {
        #if DEBUG && (targetEnvironment(simulator) || os(macOS))
        if let demoDate { return demoDate }
        #endif
        return Date()
    }

    #if DEBUG && (targetEnvironment(simulator) || os(macOS))
    private static let demoDate: Date? = {
        let seconds = UserDefaults.standard.double(forKey: "DemoDate")
        return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
    }()
    #endif
}
