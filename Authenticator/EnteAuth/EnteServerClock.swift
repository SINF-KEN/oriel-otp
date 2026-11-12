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

/// How far this device's clock is from the Ente server's, read from the `Date` header of its answers.
///
/// A wrong clock is the most common reason time-based codes are refused, the YubiKey's too, as the app gives the
/// YubiKey the time. Services accept the code before and after the current one, so a clock off by more than about 30
/// seconds starts to give codes that don't work.
nonisolated final class EnteServerClock: @unchecked Sendable {

    static let shared = EnteServerClock()

    /// How far off the clock may be before the app warns.
    static let tolerance: TimeInterval = 30

    /// An answer that took longer than this says too little about when the server wrote its `Date`.
    static let maxRoundTrip: TimeInterval = 10

    struct Measurement: Equatable, Sendable {
        /// The server's time minus this device's: positive when this device is behind.
        let offset: TimeInterval
        /// How far the real offset can be from `offset`, from the time the answer took and the header's whole seconds.
        let uncertainty: TimeInterval

        /// The offset, if the clock is certainly more than `tolerance` off.
        var skew: TimeInterval? {
            abs(offset) - uncertainty > EnteServerClock.tolerance ? offset : nil
        }
    }

    private let lock = NSLock()
    private var latest: Measurement?

    /// The last measurement, nil before any answer had a usable `Date`.
    var measurement: Measurement? {
        lock.withLock { latest }
    }

    /// Records the `Date` of an answer to a request sent at `sent` and answered at `received`, by this device's clock.
    func record(dateHeader: String?, sent: Date, received: Date) {
        guard let measurement = Self.measure(dateHeader: dateHeader, sent: sent, received: received) else { return }
        lock.withLock { latest = measurement }
    }

    static func measure(dateHeader: String?, sent: Date, received: Date) -> Measurement? {
        guard let dateHeader, let server = parse(dateHeader) else { return nil }
        let roundTrip = received.timeIntervalSince(sent)
        guard roundTrip >= 0, roundTrip <= maxRoundTrip else { return nil }
        // The server wrote the header somewhere between sending and receiving here, and cut its time to whole seconds,
        // so its time was up to a second after the header's.
        let local = sent.addingTimeInterval(roundTrip / 2)
        return Measurement(offset: server.addingTimeInterval(0.5).timeIntervalSince(local), uncertainty: roundTrip / 2 + 0.5)
    }

    /// Reads an HTTP date, e.g. "Sun, 06 Nov 1994 08:49:37 GMT".
    static func parse(_ header: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: header)
    }
}
