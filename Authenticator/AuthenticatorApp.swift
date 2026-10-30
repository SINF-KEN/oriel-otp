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

@main
struct AuthenticatorApp: App {
    
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #else
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) var appDelegate
    @State var menuBar = MenuBarSetting.shared
    @State var mainWindowState = MainWindowState.shared
    #endif
    @Environment(\.scenePhase) var scenePhase
    @State var toastPresenter = ToastPresenter()
    @State var notificationsViewModel = NotificationsViewModel()
    @State var mainViewModel = MainViewModel()

    init() {
        #if DEBUG && (targetEnvironment(simulator) || os(macOS))
        if SimulatedYubiKey.isEnabled {
            FakeEnteServer.install()
        }
        #if os(macOS)
        WindowSnapshots.scheduleIfRequested()
        WindowSnapshots.resizeMainWindowIfRequested()
        #endif
        #endif
        WatchAccountSync.shared.activate()
    }
    
    var body: some Scene {
        #if os(iOS)
        WindowGroup {
            MainView()
                .toast(isPresenting: $toastPresenter.isPresenting, message: toastPresenter.message)
                .fullScreenCover(isPresented: $notificationsViewModel.presentDisableOTP) {
                    DisableOTPView()
                }
            .fullScreenCover(isPresented: $notificationsViewModel.showPIVTokenView) {
                TokenRequestView(userInfo: notificationsViewModel.userInfo)
            }
            .transaction { transaction in
                transaction.disablesAnimations = notificationsViewModel.showPIVTokenView
            }
            .navigationViewStyle(.stack)
            .environment(toastPresenter)
            .environment(notificationsViewModel)
            .environment(mainViewModel)
        }
        #else
        // One window: the accounts all come from the one YubiKey, so a second window would only show the same list.
        Window(Text(verbatim: "Oriel OTP"), id: AppWindow.main) {
            MainView()
                .toast(isPresenting: $toastPresenter.isPresenting, message: toastPresenter.message)
                .sheet(isPresented: $notificationsViewModel.presentDisableOTP) {
                    DisableOTPView()
                        .scaledBodyFont()
                        .appLockCover()
                }
                .appLockCover()
                .withAppEnvironment(self)
                .appTextSize(bodyFont: false)
        }
        .defaultSize(width: 900, height: 600)
        .commands {
            MainCommands()
            TextSizeCommands()
        }

        Settings {
            MacSettingsView()
                .appLockCover()
                .withAppEnvironment(self)
                .appTextSize()
        }

        Window(String(localized: "About Oriel OTP", comment: "Mac app menu"), id: AppWindow.about) {
            AboutView()
                .textScaledFrame(width: 420, height: 560)
                .appTextSize()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        // Opened from the app and Help menus, not listed in the Window menu.
        .commandsRemoved()

        Window(String(localized: "How It Works", comment: "Mac Help menu"), id: AppWindow.tutorial) {
            TutorialView()
                .textScaledFrame(minWidth: 420, minHeight: 560)
                .appTextSize()
        }
        .defaultSize(width: 480, height: 620)
        .defaultPosition(.center)
        // Opened from the app and Help menus, not listed in the Window menu.
        .commandsRemoved()

        MenuBarExtra(isInserted: $menuBar.isShown) {
            MenuBarAccountsView()
                .appLockCover()
                .withAppEnvironment(self)
                .appTextSize()
        } label: {
            Image("securitykey")
                .accessibilityLabel(Text(verbatim: "Oriel OTP"))
        }
        .menuBarExtraStyle(.window)
        #endif
    }
}

#if os(macOS)
private extension View {
    func withAppEnvironment(_ app: AuthenticatorApp) -> some View {
        environment(app.toastPresenter)
            .environment(app.notificationsViewModel)
            .environment(app.mainViewModel)
            .environment(app.mainWindowState)
    }
}
#endif
