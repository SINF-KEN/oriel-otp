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

import SwiftUI
#if canImport(UIKit)
import UIKit
import UniformTypeIdentifiers
#else
import AppKit
#endif

/// What iOS and macOS do differently, behind one interface for the shared code.
enum Platform {

    /// The app runs on an iPhone, where the YubiKey can act as the keyboard over USB.
    static var isPhone: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .phone
        #else
        return false
        #endif
    }

    /// Opens a link in the browser, or another app that handles it.
    static func open(_ url: URL) {
        #if os(iOS)
        UIApplication.shared.open(url)
        #else
        NSWorkspace.shared.open(url)
        #endif
    }

    /// Whether Reduce Motion is on, for animations started outside a view, which has
    /// `accessibilityReduceMotion` in its environment.
    @MainActor static var prefersReducedMotion: Bool {
        #if os(iOS)
        UIAccessibility.isReduceMotionEnabled
        #else
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #endif
    }

    enum Feedback {
        case success
        case error
    }

    /// Haptic feedback on iPhone. Macs don't have it for this, so it does nothing there.
    static func notify(_ feedback: Feedback) {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(feedback == .success ? .success : .error)
        #endif
    }

    // How long a copied code stays on the pasteboard. The code has usually expired by then.
    private static let pasteboardLifetime: Duration = .seconds(60)

    /// Copies a code to the pasteboard.
    ///
    /// On iOS it stays on the device rather than going to the other devices through Universal Clipboard. On the Mac
    /// it's marked as concealed (https://nspasteboard.org) so clipboard managers don't keep it. On both it's removed
    /// after a while, on the Mac unless something else has been copied since.
    static func copy(_ string: String) {
        #if os(iOS)
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: string]],
                                      options: [.localOnly: true,
                                                .expirationDate: Date.now.addingTimeInterval(TimeInterval(pasteboardLifetime.components.seconds))])
        #else
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        let changeCount = pasteboard.changeCount
        Task {
            try? await Task.sleep(for: pasteboardLifetime)
            guard NSPasteboard.general.changeCount == changeCount else { return }
            NSPasteboard.general.clearContents()
        }
        #endif
    }
}

#if os(macOS)
// The iOS system colors used by the shared views, under their iOS names.
extension NSColor {
    static var label: NSColor { .labelColor }
    static var secondaryLabel: NSColor { .secondaryLabelColor }
    static var tertiaryLabel: NSColor { .tertiaryLabelColor }
    static var separator: NSColor { .separatorColor }
    static var systemBackground: NSColor { .windowBackgroundColor }
    static var secondarySystemBackground: NSColor { .controlBackgroundColor }
}

// The keyboard and navigation bar modifiers only exist on iOS. They do nothing on the Mac, so the shared views can keep
// using them without checking the platform each time.
enum UIKeyboardType {
    case asciiCapable
    case asciiCapableNumberPad
    case emailAddress
    case numberPad
    case numbersAndPunctuation
    case URL
}

struct TextInputAutocapitalization {
    static let never = TextInputAutocapitalization()
    static let characters = TextInputAutocapitalization()
}

enum NavigationBarTitleDisplayMode {
    case inline
    case large
}

extension View {
    func keyboardType(_ type: UIKeyboardType) -> some View { self }
    func textInputAutocapitalization(_ autocapitalization: TextInputAutocapitalization?) -> some View { self }
    func navigationBarTitleDisplayMode(_ displayMode: NavigationBarTitleDisplayMode) -> some View { self }
}
#endif
