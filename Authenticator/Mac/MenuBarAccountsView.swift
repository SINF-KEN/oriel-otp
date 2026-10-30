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

import SwiftUI

/// The menu bar extra: the pinned accounts, or all of them when none are pinned. Clicking one copies its code.
///
/// It connects to the YubiKey while it's open if the main window isn't, and lets go of it again when it closes.
struct MenuBarAccountsView: View {

    @Environment(MainViewModel.self) private var model
    @Environment(ToastPresenter.self) private var toastPresenter
    @Environment(MainWindowState.self) private var mainWindow
    @Environment(\.openWindow) private var openWindow
    @State private var copiedAccountID: String?
    @State private var startedModel = false

    private var accounts: [Account] {
        model.pinnedAccounts.isEmpty ? model.accounts : model.pinnedAccounts
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !model.hasAccounts {
                Label(model.isKeyPluggedIn ? String(localized: "Reading YubiKey…", comment: "Mac menu bar") : String(localized: "Insert YubiKey"),
                      image: "securitykey")
                    .foregroundStyle(.secondary)
                    .padding(8)
            } else if accounts.isEmpty {
                Text("No accounts on YubiKey")
                    .foregroundStyle(.secondary)
                    .padding(8)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(accounts, id: \.id) { account in
                            MenuBarAccountRow(account: account, isCopied: copiedAccountID == account.accountId) {
                                copy(account)
                            }
                        }
                    }
                }
                .frame(maxHeight: 420)
                .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
                .padding(.vertical, 4)
            MenuBarButton(String(localized: "Open Oriel OTP", comment: "Mac menu bar")) {
                openWindow(id: AppWindow.main)
                NSApp.activate()
            }
            SettingsLink {
                Text(String(localized: "Settings…", comment: "Mac menu bar"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            MenuBarButton(String(localized: "Quit Oriel OTP", comment: "Mac menu bar")) {
                NSApp.terminate(nil)
            }
        }
        .padding(6)
        .frame(width: 300)
        .onAppear {
            guard !mainWindow.isVisible, !model.isStarted else { return }
            startedModel = true
            ConnectionManager.shared.resumeWiredConnections()
            model.start()
        }
        .onDisappear {
            guard startedModel, !mainWindow.isVisible else { return }
            startedModel = false
            model.stop()
            Task { await model.closeConnections() }
        }
    }

    private func copy(_ account: Account) {
        toastPresenter.copyCode(of: account)
        copiedAccountID = account.accountId
        Task {
            try? await Task.sleep(for: .seconds(2))
            if copiedAccountID == account.accountId {
                copiedAccountID = nil
            }
        }
    }
}

private struct MenuBarAccountRow: View {
    let account: Account
    let isCopied: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.title)
                        .lineLimit(1)
                    account.subTitle.map {
                        Text($0)
                            .font(.caption)
                            .foregroundStyle(isHovering ? .primary : .secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if isCopied {
                    Label(String(localized: "Copied", comment: "Mac menu bar"), systemImage: "checkmark")
                        .labelStyle(.titleAndIcon)
                } else if account.requiresTouch && account.otp == nil {
                    Image(systemName: "hand.tap")
                        .help(String(localized: "Requires touch", comment: "Mac menu bar help"))
                } else {
                    Text(account.state == .expired ? "*** ***" : account.formattedCode ?? "*** ***")
                        .font(.body.monospacedDigit().bold())
                        .privacySensitive()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(isHovering ? Color.white : Color.primary)
            .background(isHovering ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(account.title)
        .accessibilityHint(String(localized: "Copies the code", comment: "Mac menu bar accessibility hint"))
    }
}

private struct MenuBarButton: View {
    let title: String
    let action: () -> Void
    @State private var isHovering = false

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .foregroundStyle(isHovering ? Color.white : Color.primary)
                .background(isHovering ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

#endif
