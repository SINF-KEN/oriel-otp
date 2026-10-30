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
import Observation

/// Whether the main window is open and in use, so the menu bar and Shortcuts know if they have to connect to the
/// YubiKey themselves.
@MainActor @Observable final class MainWindowState {
    static let shared = MainWindowState()
    var isVisible = false
}

final class MacAppDelegate: NSObject, NSApplicationDelegate {

    func applicationWillFinishLaunching(_ notification: Notification) {
        MacPreferences.applyActivationPolicy()
        #if DEBUG
        WindowSnapshots.applyDemoAppearance()
        #endif
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Locked when the screen locks, the Mac sleeps or another user takes over, and asked for when the app is
        // next used.
        let lock: @Sendable (Notification) -> Void = { _ in Task { @MainActor in AppLock.shared.lock() } }
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main, using: lock)
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main, using: lock)
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in AppLock.shared.didBecomeActive() }
        }
    }

    // The Dock menu, in place of the Home Screen quick actions on iOS.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: String(localized: "Add Account…", comment: "Mac File menu"), action: #selector(addAccount), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func addAccount() {
        QuickAction.addAccount.perform()
    }
}

extension QuickAction {
    /// The URL that asks the app to do the action. Opening it brings up the main window, also when it was closed.
    var url: URL {
        switch self {
        case .addAccount: URL(string: "orielotp://add-account")!
        case .scanNFC: URL(string: "orielotp://scan-nfc")!
        }
    }

    init?(url: URL) {
        guard let action = [QuickAction.addAccount, .scanNFC].first(where: { $0.url == url }) else { return nil }
        self = action
    }

    func perform() {
        NSWorkspace.shared.open(url)
    }
}

#endif
