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
import SwiftUI
import YubiKit

/// What the menu bar commands can do in the main window. The main view publishes it while its window is in front.
///
/// It's only the state, compared with `==`, so the menus are rebuilt when it changes and not on every update of the
/// view, such as the countdown of the codes. The commands ask the main view to act through ``MainWindowCommands``.
struct MainWindowMenuState: Equatable {
    var canAddAccount = false
    var canRefresh = false
    var canSearch = false
    var selectionCount = 0
    var isSelectionPinned = false
    var canRename = false
}

extension FocusedValues {
    @Entry var mainWindowMenuState: MainWindowMenuState?
}

/// Passes the menu bar commands to the main view, which does them in ``MainView/perform(_:)``.
@MainActor @Observable final class MainWindowCommands {
    static let shared = MainWindowCommands()

    enum Command: Equatable {
        case addAccount, syncFromEnte, refresh, search, copyCode, togglePin, rename, delete
    }

    var pending: Command?

    func send(_ command: Command) {
        pending = command
    }
}

/// The commands in the menu bar. Every action of the main window is here, most with a keyboard shortcut.
struct MainCommands: Commands {

    @FocusedValue(\.mainWindowMenuState) private var state
    @Environment(\.openWindow) private var openWindow
    private let commands = MainWindowCommands.shared

    private var selectionCount: Int { state?.selectionCount ?? 0 }

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(String(localized: "About Oriel OTP", comment: "Mac app menu")) {
                openWindow(id: AppWindow.about)
            }
        }

        CommandGroup(replacing: .newItem) {
            Button(String(localized: "Add Account…", comment: "Mac File menu")) {
                commands.send(.addAccount)
            }
            .keyboardShortcut("n")
            .disabled(state?.canAddAccount != true)
            Button(String(localized: "Sync from Ente Auth…", comment: "Mac File menu")) {
                commands.send(.syncFromEnte)
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(state == nil)
        }

        // Copy copies the selected account's code, unless text is being edited, e.g. in the search field.
        CommandGroup(replacing: .pasteboard) {
            Button(String(localized: "Cut", comment: "Mac Edit menu")) {
                sendToTextField(#selector(NSText.cut(_:)))
            }
            .keyboardShortcut("x")
            Button(String(localized: "Copy", comment: "Mac Edit menu")) {
                if !isEditingText, selectionCount == 1 {
                    commands.send(.copyCode)
                } else {
                    sendToTextField(#selector(NSText.copy(_:)))
                }
            }
            .keyboardShortcut("c")
            Button(String(localized: "Paste", comment: "Mac Edit menu")) {
                sendToTextField(#selector(NSText.paste(_:)))
            }
            .keyboardShortcut("v")
            Button(String(localized: "Select All", comment: "Mac Edit menu")) {
                sendToTextField(#selector(NSText.selectAll(_:)))
            }
            .keyboardShortcut("a")
        }

        CommandGroup(after: .textEditing) {
            Button(String(localized: "Search Accounts", comment: "Mac Edit menu")) {
                commands.send(.search)
            }
            .keyboardShortcut("f")
            .disabled(state?.canSearch != true)
        }

        CommandMenu(String(localized: "Account", comment: "Mac menu title")) {
            Button(String(localized: "Copy Code", comment: "Mac Account menu")) {
                commands.send(.copyCode)
            }
            .disabled(selectionCount != 1)
            Button(state?.isSelectionPinned == true ? String(localized: "Unpin", comment: "Mac Account menu") : String(localized: "Pin", comment: "Mac Account menu")) {
                commands.send(.togglePin)
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(selectionCount == 0)
            Button(String(localized: "Rename…", comment: "Mac Account menu")) {
                commands.send(.rename)
            }
            .disabled(state?.canRename != true)
            Divider()
            Button(selectionCount > 1 ? String(localized: "Delete Accounts…", comment: "Mac Account menu") : String(localized: "Delete…", comment: "Mac Account menu")) {
                if isEditingText {
                    sendToTextField(#selector(NSResponder.deleteToBeginningOfLine(_:)))
                } else {
                    commands.send(.delete)
                }
            }
            .keyboardShortcut(.delete)
            .disabled(selectionCount == 0)
            Divider()
            Button(String(localized: "Refresh", comment: "Mac Account menu")) {
                commands.send(.refresh)
            }
            .keyboardShortcut("r")
            .disabled(state?.canRefresh != true)
        }

        #if DEBUG
        CommandMenu(Text(verbatim: "Debug")) {
            if SimulatedYubiKey.isEnabled {
                SimulatedYubiKeyMenu()
                SimulatedYubicoOTPButton()
            } else {
                Text(verbatim: "Launch with -SimulatedYubiKey YES for the simulated YubiKey")
            }
        }
        #endif

        // Import from iPhone or iPad, for taking a picture of a QR code with Continuity Camera.
        ImportFromDevicesCommands()

        CommandGroup(replacing: .help) {
            Button(String(localized: "Oriel OTP Help", comment: "Mac Help menu")) {
                Platform.open(URL(string: "https://github.com/SINF-KEN/oriel-otp#readme")!)
            }
            Button(String(localized: "How It Works", comment: "Mac Help menu")) {
                openWindow(id: AppWindow.tutorial)
            }
            Divider()
            Button(String(localized: "Support", comment: "Mac Help menu")) {
                Platform.open(URL(string: "https://github.com/SINF-KEN/oriel-otp/blob/main/SUPPORT.md")!)
            }
            Button(String(localized: "Privacy Policy", comment: "Mac Help menu")) {
                Platform.open(URL(string: "https://github.com/SINF-KEN/oriel-otp/blob/main/PRIVACY.md")!)
            }
        }
    }

    // The field editor of a text field, e.g. the search field, is first responder while text is edited.
    private var isEditingText: Bool {
        NSApp.keyWindow?.firstResponder is NSText
    }

    private func sendToTextField(_ action: Selector) {
        NSApp.sendAction(action, to: nil, from: nil)
    }
}

/// The ids of the app's windows besides the main one.
enum AppWindow {
    static let main = "main"
    static let about = "about"
    static let tutorial = "tutorial"
}

// For the rename sheet.
extension Account: Identifiable {}

extension Account {
    /// Renaming needs firmware 5.3 or later.
    var canRename: Bool { keyVersion >= Version("5.3.0")! }
}

#endif
