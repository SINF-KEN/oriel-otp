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

import SwiftUI

/// Says that the device's clock is wrong, which makes time-based codes fail, and how to set it right. Shown above the
/// accounts after a sync with Ente found the clock more than `EnteServerClock.tolerance` off.
struct ClockWarningRow: View {
    /// The server's time minus this device's.
    let skew: TimeInterval

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.problem(skew: skew))
                    .scaledFont(.subheadline) { $0.weight(.semibold) }
                Text(Self.fix)
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "clock.badge.exclamationmark")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("accounts.clock-warning")
    }

    /// How far off the clock is, e.g. "2 minutes, 5 seconds".
    static func amount(_ skew: TimeInterval) -> String {
        let seconds = Int(abs(skew).rounded())
        return Duration.seconds(seconds).formatted(
            .units(
                allowed: [.days, .hours, .minutes, .seconds], width: .wide,
                maximumUnitCount: 2))
    }

    static func problem(skew: TimeInterval) -> String {
        let amount = amount(skew)
        return skew > 0
            ? String(
                localized: "This device's clock is \(amount) behind, so codes may not work.",
                comment:
                    "Warning above the accounts when the device's clock is wrong. The placeholder is how far, e.g. 2 minutes, 5 seconds.")
            : String(
                localized: "This device's clock is \(amount) ahead, so codes may not work.",
                comment:
                    "Warning above the accounts when the device's clock is wrong. The placeholder is how far, e.g. 2 minutes, 5 seconds.")
    }

    static var fix: String {
        #if os(macOS)
            String(
                localized: "Turn on setting the time automatically in System Settings > General > Date & Time.",
                comment: "How to fix the device's clock, on the Mac")
        #else
            String(
                localized: "Turn on Set Automatically in Settings > General > Date & Time.",
                comment: "How to fix the device's clock, on iPhone and iPad")
        #endif
    }
}
