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

import SwiftUI


@Observable class ToastPresenter {
    var isPresenting = false
    var message = "No message"
    
    @ObservationIgnored private var presentTask: Task<Void, any Error>?
    @ObservationIgnored private var dismissTask: Task<Void, any Error>?
    // The latest message asked for, which may still be waiting for the previous toast to go away.
    @ObservationIgnored private var requestedMessage: String?

    /// Shows the message, and hides it after `duration`, or only when `dismiss(message:)` is called if `duration` is nil.
    /// A longer message stays longer than `duration`, long enough to read it at a slow pace.
    func toast(message: String, duration: Duration? = .seconds(4)) {
        presentTask?.cancel()
        dismissTask?.cancel()
        requestedMessage = message

        if isPresenting {
            isPresenting = false
            presentTask = Task { [weak self] in
                try await Task.sleep(for: .milliseconds(300))
                self?.present(message, duration: duration)
            }
        } else {
            present(message, duration: duration)
        }
    }

    /// Hides the toast if it shows, or is about to show, this message.
    func dismiss(message: String) {
        guard requestedMessage == message else { return }
        presentTask?.cancel()
        dismissTask?.cancel()
        requestedMessage = nil
        isPresenting = false
    }

    private func present(_ message: String, duration: Duration?) {
        self.message = message
        isPresenting = true
        AccessibilityNotification.Announcement(message).post()
        guard var duration else { return }
        // About ten characters a second, so "Moved to the YubiKey. Ente Auth keeps it in the trash." stays 6 seconds.
        duration = max(duration, .milliseconds(message.count * 100))
        dismissTask = Task { [weak self] in
            try await Task.sleep(for: duration)
            self?.isPresenting = false
            self?.requestedMessage = nil
            self?.dismissTask = nil
        }
    }
}

extension ToastPresenter {
    
    func copyToClipboard(_ value: String) {
        Platform.copy(value)
        toast(message: String(localized: "Copied to clipboard", comment: "Toast copied to clipboard message"))
        Platform.notify(.success)
    }

    /// Copies the account's code, calculating a new one first if there's none or it has expired.
    func copyCode(of account: Account) {
        if account.state != .expired, let otp = account.otp?.code {
            copyToClipboard(otp)
        } else {
            account.calculate { [weak self] otp in
                self?.copyToClipboard(otp.code)
            }
        }
    }
}
