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

import AppKit
import Carbon.HIToolbox
import SwiftUI

/// **Quick Copy** on the Mac: a keyboard shortcut that works in any app and opens a search panel like Spotlight's.
/// Typing finds an account by its name, issuer or tags, the arrow keys choose one and Return copies its code.
///
/// The panel doesn't activate the app, so the app that was in front stays there, ready for the code to be pasted.
@MainActor @Observable final class QuickCopy {

    static let shared = QuickCopy()

    static let isEnabledKey = "QuickCopy.Enabled"
    /// ⌥⌘O, shown in the settings.
    static let shortcutTitle = "⌥⌘O"
    private static let keyCode = UInt32(kVK_ANSI_O)
    private static let modifiers = UInt32(optionKey | cmdKey)

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.isEnabledKey)
            applySetting()
        }
    }

    /// Set when another app already uses the shortcut.
    private(set) var isShortcutTaken = false

    /// The panel's content, with the app's environment. Set once by the app.
    @ObservationIgnored var makeContent: (() -> AnyView)?
    @ObservationIgnored private var hotKey: GlobalHotKey?
    @ObservationIgnored private var panel: QuickCopyPanel?

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.isEnabledKey)
    }

    /// Registers or removes the shortcut, as the setting says.
    func applySetting() {
        hotKey = nil
        isShortcutTaken = false
        guard isEnabled else {
            close()
            return
        }
        hotKey = GlobalHotKey(keyCode: Self.keyCode, modifiers: Self.modifiers) { [weak self] in
            self?.toggle()
        }
        isShortcutTaken = hotKey == nil
    }

    func toggle() {
        if let panel, panel.isVisible {
            close()
        } else {
            open()
        }
    }

    private func open() {
        guard let makeContent else { return }
        let panel = panel ?? QuickCopyPanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: makeContent())
        panel.showCentered()
    }

    /// Closes the panel. The app in front before stays in front, as the panel never activated this one.
    func close() {
        panel?.orderOut(nil)
        panel?.contentView = nil
    }
}

/// A floating panel that takes the keyboard without bringing the app to the front, and goes away when another window
/// takes it.
private final class QuickCopyPanel: NSPanel {

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        setAccessibilitySubrole(.dialog)
        setAccessibilityTitle(String(localized: "Quick Copy", comment: "Mac Quick Copy panel title, read by VoiceOver"))
    }

    override var canBecomeKey: Bool { true }

    /// On the screen with the pointer, a little above the middle, like Spotlight.
    func showCentered() {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            setFrameTopLeftPoint(NSPoint(x: visible.midX - frame.width / 2, y: visible.maxY - visible.height * 0.22))
        }
        makeKeyAndOrderFront(nil)
    }

    override func resignKey() {
        super.resignKey()
        MainActor.assumeIsolated { QuickCopy.shared.close() }
    }

    override func cancelOperation(_ sender: Any?) {
        MainActor.assumeIsolated { QuickCopy.shared.close() }
    }
}

/// A shortcut registered with the system, which works whichever app is in front and needs no permission.
private final class GlobalHotKey {

    // Only set in init and read in deinit.
    nonisolated(unsafe) private var hotKeyRef: EventHotKeyRef?
    nonisolated(unsafe) private var handlerRef: EventHandlerRef?
    private let action: @MainActor () -> Void

    /// Nil when the shortcut can't be registered, e.g. another app has it.
    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping @MainActor () -> Void) {
        self.action = action
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                MainActor.assumeIsolated { hotKey.action() }
                return noErr
            }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        guard status == noErr else { return nil }
        let id = EventHotKeyID(signature: OSType(0x4F_52_4F_54), id: 1)  // "OROT"
        guard RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef) == noErr else {
            RemoveEventHandler(handlerRef)
            handlerRef = nil
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}

/// The search field and the accounts it finds. Return copies the chosen one's code and closes the panel.
struct QuickCopyView: View {

    @Environment(MainViewModel.self) private var model
    @Environment(ToastPresenter.self) private var toastPresenter
    @Environment(MainWindowState.self) private var mainWindow
    @State private var searchText = ""
    @State private var selectedID: String?
    @State private var startedModel = false
    @FocusState private var isSearchFocused: Bool

    private var results: [Account] {
        QuickCopySearch.results(in: AccountUsage.shared.ordered(model.accounts, id: \.accountId), for: searchText)
    }

    var body: some View {
        Group {
            if AppLock.shared.isLocked {
                ScrollView {
                    AppLockPrompt()
                        .padding(16)
                }
            } else {
                search
            }
        }
        .frame(width: 560, height: 360)
        .onAppear(perform: start)
        .onDisappear(perform: stop)
    }

    private var search: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField(String(localized: "Search accounts", comment: "Mac Quick Copy search field"), text: $searchText)
                    .textFieldStyle(.plain)
                    .scaledFont(.title2)
                    .focused($isSearchFocused)
                    .onSubmit(copySelected)
                    .onKeyPress(.downArrow) { moveSelection(by: 1) }
                    .onKeyPress(.upArrow) { moveSelection(by: -1) }
                    .accessibilityIdentifier("quick-copy.search")
            }
            .padding(14)
            Divider()
            if results.isEmpty {
                Text(
                    model.hasAccounts
                        ? String(
                            localized: "No matching accounts", comment: "Search without results when Ente Auth accounts are listed too")
                        : String(localized: "No accounts yet", comment: "Account list without accounts")
                )
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(results, id: \.accountId, selection: $selectedID) { account in
                        QuickCopyRow(account: account)
                            .tag(account.accountId)
                            .id(account.accountId)
                    }
                    .listStyle(.plain)
                    .onChange(of: selectedID) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
            Divider()
            Text(String(localized: "Return copies the code. Esc closes.", comment: "Mac Quick Copy footer"))
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
        }
        .onChange(of: searchText) { selectedID = results.first?.accountId }
        .defaultFocus($isSearchFocused, true)
        .onAppear {
            selectedID = results.first?.accountId
            // Once the panel is key, which it becomes just after it shows.
            Task { isSearchFocused = true }
        }
    }

    private func moveSelection(by offset: Int) -> KeyPress.Result {
        let ids = results.map(\.accountId)
        guard !ids.isEmpty else { return .handled }
        let index = selectedID.flatMap { ids.firstIndex(of: $0) } ?? -offset
        selectedID = ids[min(max(index + offset, 0), ids.count - 1)]
        return .handled
    }

    private func copySelected() {
        guard let account = results.first(where: { $0.accountId == selectedID }) ?? results.first else { return }
        toastPresenter.copyCode(of: account)
        QuickCopy.shared.close()
    }

    /// Connects to the YubiKey while the panel is open if the main window isn't, like the menu bar.
    private func start() {
        model.setCountdownsVisible(true, in: .menuBar)
        guard !mainWindow.isVisible, !model.isStarted else { return }
        startedModel = true
        ConnectionManager.shared.resumeWiredConnections()
        model.start()
    }

    private func stop() {
        model.setCountdownsVisible(false, in: .menuBar)
        guard startedModel, !mainWindow.isVisible else { return }
        startedModel = false
        model.stop()
        Task { await model.closeConnections() }
    }
}

/// Finding accounts in Quick Copy, the way the main window's search does.
enum QuickCopySearch {
    /// All the accounts for an empty search, otherwise the ones whose title, name or tags match, those starting with
    /// it first.
    static func results(in accounts: [Account], for text: String) -> [Account] {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return accounts }
        let matches = accounts.filter {
            $0.title.localizedStandardContains(text) || $0.subTitle?.localizedStandardContains(text) == true
                || $0.tags.contains { $0.localizedStandardContains(text) }
        }
        let prefix = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let startsWith = matches.filter {
            $0.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).hasPrefix(prefix)
        }
        return startsWith + matches.filter { !startsWith.contains($0) }
    }
}

private struct QuickCopyRow: View {
    let account: Account

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(account.title.leftToRightIfAddress)
                    .lineLimit(1)
                account.subTitle.map {
                    Text($0.leftToRightIfAddress)
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if account.requiresTouch && account.otp == nil {
                Image(systemName: "hand.tap")
                    .help(String(localized: "Requires touch", comment: "Mac menu bar help"))
            } else {
                Text(account.displayedCode ?? "*** ***")
                    .scaledFont(.body) { $0.monospacedDigit().bold() }
                    .privacySensitive()
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(([account.title] + [account.subTitle].compactMap { $0 }).joined(separator: String.accessibilitySeparator))
        .accessibilityValue(
            account.requiresTouch && account.otp == nil
                ? String(localized: "Requires touch", comment: "Mac menu bar help") : account.spokenCode)
    }
}

/// **Quick Copy** in the General settings.
struct QuickCopySection: View {
    @Bindable private var quickCopy = QuickCopy.shared

    var body: some View {
        Section {
            Toggle(
                String(
                    localized: "Quick Copy with \(QuickCopy.shortcutTitle)",
                    comment: "Mac setting. The placeholder is a keyboard shortcut, e.g. ⌥⌘O."),
                isOn: $quickCopy.isEnabled)
        } footer: {
            if quickCopy.isShortcutTaken {
                Text(
                    String(
                        localized:
                            "Another app already uses \(QuickCopy.shortcutTitle). Quit it or change its shortcut, then turn Quick Copy off and on.",
                        comment: "Mac setting footer. The placeholder is a keyboard shortcut, e.g. ⌥⌘O.")
                )
                .foregroundStyle(.red)
            } else {
                Text(
                    String(
                        localized: "Press the shortcut in any app, type an account's name and press Return to copy its code.",
                        comment: "Mac setting footer"))
            }
        }
    }
}
