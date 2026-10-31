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

#if os(macOS)

import AppKit
import UserNotifications

/// Asks for a touch of the YubiKey with a notification when the code was asked for from outside the window, e.g. from
/// the menu bar or Shortcuts, where the in-window prompt can't be seen. The notification is removed once the YubiKey
/// has been touched.
enum TouchPrompt {

    private static let identifier = "io.github.sinf-ken.OrielOTP.touch"

    /// Whether the notification should be up, i.e. `show()` was called and `hide()` hasn't been since. `hide()` can
    /// come before the notification has been added, e.g. while permission is being asked for.
    private static var isShown = false
    /// Changes with every `show()` and `hide()`, so only the latest `show()` adds the notification.
    private static var generation = 0

    static func show(for accountTitle: String) {
        guard !NSApp.isActive else { return }
        let center = UNUserNotificationCenter.current()
        isShown = true
        generation += 1
        let generation = generation
        Task {
            // Asked the first time it's needed, so the request comes with a reason.
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true,
                  generation == Self.generation else { return }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Touch your YubiKey", comment: "Mac notification title")
            content.body = String(localized: "Touch the button on the YubiKey to get the code for \(accountTitle.isolated).", comment: "Mac notification. The placeholder is the account name.")
            content.interruptionLevel = .timeSensitive
            try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
            // Hidden while it was being added.
            if !isShown {
                remove()
            }
        }
    }

    static func hide() {
        isShown = false
        generation += 1
        remove()
    }

    private static func remove() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}

#endif
