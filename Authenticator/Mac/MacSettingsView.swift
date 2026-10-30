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

import ServiceManagement
import SwiftUI

/// The Mac's Settings window (⌘,): the app's own settings and the YubiKey configuration, which is a sheet on iOS.
struct MacSettingsView: View {

    var body: some View {
        TabView {
            GeneralSettingsView()
                .textScaledFrame(width: 520, height: 480)
                .tabItem { Label(String(localized: "General", comment: "Mac settings tab"), systemImage: "gearshape") }
            YubiKeySettingsView()
                .textScaledFrame(width: 520, height: 560)
                .tabItem { Label(String(localized: "YubiKey", comment: "Mac settings tab"), image: "securitykey") }
        }
    }
}

/// Whether the menu bar extra is shown. The scene's binding can't be @AppStorage, which makes SwiftUI update the
/// scenes over and over.
@MainActor @Observable final class MenuBarSetting {
    static let shared = MenuBarSetting()

    var isShown = UserDefaults.standard.object(forKey: MacPreferences.showInMenuBar) as? Bool ?? true {
        didSet {
            guard isShown != oldValue else { return }
            UserDefaults.standard.set(isShown, forKey: MacPreferences.showInMenuBar)
            MacPreferences.applyActivationPolicy()
        }
    }
}

/// Keys of the Mac-only settings in UserDefaults.
enum MacPreferences {
    static let showInMenuBar = "Mac.ShowInMenuBar"
    static let menuBarOnly = "Mac.MenuBarOnly"

    /// Hides the app from the Dock and the app switcher when it should only be in the menu bar.
    static func applyActivationPolicy() {
        let defaults = UserDefaults.standard
        let showInMenuBar = defaults.object(forKey: showInMenuBar) as? Bool ?? true
        let menuBarOnly = showInMenuBar && defaults.bool(forKey: menuBarOnly)
        NSApp.setActivationPolicy(menuBarOnly ? .accessory : .regular)
    }
}

private struct GeneralSettingsView: View {

    @Bindable private var menuBar = MenuBarSetting.shared
    @AppStorage(MacPreferences.menuBarOnly) private var menuBarOnly = false
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section {
                Toggle(String(localized: "Show in menu bar", comment: "Mac setting"), isOn: $menuBar.isShown)
                Toggle(String(localized: "Show only in menu bar", comment: "Mac setting"), isOn: $menuBarOnly)
                    .disabled(!menuBar.isShown)
            } footer: {
                Text(String(localized: "The menu bar shows your pinned accounts, or all accounts if none are pinned. Click one to copy its code. When the app is only in the menu bar, it isn't in the Dock.", comment: "Mac setting footer"))
            }
            Section {
                TextSizePicker()
            } footer: {
                Text(String(localized: "Also in the View menu: Make Text Bigger (⌘+), Make Text Smaller (⌘−) and Actual Size (⌘0).", comment: "Mac setting footer"))
            }
            Section {
                Toggle(String(localized: "Open at login", comment: "Mac setting"), isOn: $opensAtLogin)
            }
            AppLockSection()
            EnteAccountSection()
        }
        .formStyle(.grouped)
        .scaledButtonLabels()
        .onChange(of: menuBarOnly) { MacPreferences.applyActivationPolicy() }
        .onChange(of: opensAtLogin) { _, opensAtLogin in
            do {
                if opensAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                loginItemError = error.localizedDescription
            }
        }
        .alert(String(localized: "Couldn't change the login item", comment: "Mac setting error"),
               isPresented: Binding(get: { loginItemError != nil }, set: { if !$0 { loginItemError = nil } })) {
            Button("OK", role: .cancel) {
                opensAtLogin = SMAppService.mainApp.status == .enabled
            }
        } message: {
            Text(loginItemError ?? "")
        }
    }
}

/// The YubiKey configuration. The YubiKey is handed to one view at a time, so the account list lets go of it while
/// this tab is shown.
private struct YubiKeySettingsView: View {

    @Environment(MainViewModel.self) private var model
    @Environment(MainWindowState.self) private var mainWindow

    var body: some View {
        ConfigurationView(showConfiguration: .constant(true))
            .onAppear {
                model.stop()
                ConnectionManager.shared.resumeWiredConnections()
            }
            .onDisappear {
                if mainWindow.isVisible {
                    model.start()
                } else {
                    Task { await model.closeConnections() }
                }
            }
    }
}

#endif
