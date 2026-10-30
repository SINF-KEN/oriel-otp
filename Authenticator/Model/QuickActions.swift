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

#if os(iOS)
import UIKit
#endif
import AppIntents

/// What the app can be asked to do from outside it: Home Screen quick actions, Siri and Shortcuts.
enum QuickAction: String {
    case scanNFC = "io.github.sinf-ken.OrielOTP.scan-nfc"
    case addAccount = "io.github.sinf-ken.OrielOTP.add-account"

    #if os(iOS)
    /// The Home Screen quick actions this device can do.
    @MainActor static var shortcutItems: [UIApplicationShortcutItem] {
        var items = [UIApplicationShortcutItem]()
        if DeviceCapabilities.supportsNFC {
            items.append(UIApplicationShortcutItem(type: QuickAction.scanNFC.rawValue,
                                                   localizedTitle: String(localized: "Scan NFC YubiKey"),
                                                   localizedSubtitle: nil,
                                                   icon: UIApplicationShortcutIcon(systemImageName: "wave.3.right")))
        }
        items.append(UIApplicationShortcutItem(type: QuickAction.addAccount.rawValue,
                                               localizedTitle: String(localized: "Add account"),
                                               localizedSubtitle: nil,
                                               icon: UIApplicationShortcutIcon(systemImageName: "plus")))
        return items
    }
    #endif
}

/// Holds the latest quick action until the main view is active and can do it.
@MainActor @Observable final class QuickActionCenter {
    static let shared = QuickActionCenter()
    var pending: QuickAction?
}

#if os(iOS)
final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.shortcutItems = QuickAction.shortcutItems
        return true
    }

    // A quick action that launches the app arrives here rather than in the scene delegate.
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if let item = options.shortcutItem, let action = QuickAction(rawValue: item.type) {
            QuickActionCenter.shared.pending = action
        }
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {

    private var appLockWindow: AppLockWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        appLockWindow = AppLockWindow(windowScene: windowScene)
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        AppLock.shared.didBecomeActive()
    }

    // Not when the scene only resigns active, as the NFC and Face ID sheets make it do.
    func sceneDidEnterBackground(_ scene: UIScene) {
        AppLock.shared.lock()
        appLockWindow?.update(animated: false)
    }

    // A quick action used while the app is running.
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem) async -> Bool {
        guard let action = QuickAction(rawValue: shortcutItem.type) else { return false }
        QuickActionCenter.shared.pending = action
        return true
    }
}

struct ScanNFCYubiKeyIntent: AppIntent {
    static let title: LocalizedStringResource = "Scan NFC YubiKey"
    static let description = IntentDescription("Opens Oriel OTP and reads the codes from a YubiKey over NFC.")
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        QuickActionCenter.shared.pending = .scanNFC
        return .result()
    }
}

struct OrielOTPShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ScanNFCYubiKeyIntent(),
                    phrases: ["Scan a YubiKey with \(.applicationName)",
                              "Show my codes in \(.applicationName)"],
                    shortTitle: "Scan NFC YubiKey",
                    systemImageName: "wave.3.right")
    }
}
#endif
