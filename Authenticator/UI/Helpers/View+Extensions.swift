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


extension View {
    func readFrame(_ frame: Binding<CGRect>) -> some View {
        self.modifier(FrameReaderModifier(frame: frame))
    }
}

struct FrameReaderModifier: ViewModifier  {
    @Binding var frame: CGRect
    
    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self) { geometry in
            geometry.frame(in: CoordinateSpace.global)
        } action: { newFrame in
            frame = newFrame
        }
    }
}


extension View {
    func readSize(_ size: Binding<CGSize>) -> some View {
        self.modifier(SizeReaderModifier(size: size))
    }
}

struct SizeReaderModifier: ViewModifier  {
    @Binding var size: CGSize
    
    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGSize.self) { geometry in
            geometry.size
        } action: { newSize in
            size = newSize
        }
    }
}


extension View {
    @ViewBuilder func refreshable(enabled: Bool, action: @escaping () async -> Void) -> some View {
        if enabled {
            self.refreshable {
                await action()
            }
        } else {
            self
        }
    }
}

// Toolbar buttons that use the system Close, Cancel and Confirm roles on iOS 26 and later, so the bar draws the
// standard glyphs and prominent styling and can lay them out vertically, and fall back to text buttons before that.
struct CloseButton: View {
    let action: () -> Void

    var body: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            Button(role: .close, action: action)
        } else {
            Button(String(localized: "Close"), action: action)
        }
    }
}

struct CancelButton: View {
    let action: () -> Void

    var body: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            Button(role: .cancel, action: action)
        } else {
            Button(String(localized: "Cancel"), role: .cancel, action: action)
        }
    }
}

struct ConfirmButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            Button(title, role: .confirm, action: action)
        } else {
            Button(title, action: action)
        }
    }
}

extension View {
    // Lays the view out in the largest part of its frame that the fold and the camera housing leave clear.
    func avoidingReservedRegions() -> some View {
        self.modifier(ReservedRegionAvoidingModifier())
    }
}

struct ReservedRegionAvoidingModifier: ViewModifier {

    @ViewBuilder func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 27.1, *) {
            GeometryReader { proxy in
                let regions = proxy.reservedRegions(kind: .division) + proxy.reservedRegions(kind: .occlusion)
                let clearRect = CGRect(origin: .zero, size: proxy.size).largestClearRect(avoiding: regions.map(\.frame))
                content.padding(EdgeInsets(top: clearRect.minY,
                                           leading: clearRect.minX,
                                           bottom: proxy.size.height - clearRect.maxY,
                                           trailing: proxy.size.width - clearRect.maxX))
            }
        } else {
            content
        }
        #else
        // Mac windows have no reserved regions.
        content
        #endif
    }
}

// The filled and plain action buttons of the Yubico OTP screens, in glass on iOS 26 and later.
extension View {
    @ViewBuilder func prominentActionButtonStyle() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder func secondaryActionButtonStyle() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }
}

/// The names Voice Control accepts for a button: its visible title first, so "Tap Add account" works as shown, then
/// shorter or more natural ones, e.g. "Tap Plus" for the + button.
enum VoiceControlNames {
    static var addAccount: [String] {
        [String(localized: "Add account"), String(localized: "Add", comment: "Voice Control name for the Add account button"),
         String(localized: "Plus", comment: "Voice Control name for the Add account button, after its + symbol"),
         String(localized: "New account", comment: "Voice Control name for the Add account button")]
    }
    static var scanNFC: [String] {
        [String(localized: "Scan NFC YubiKey"), String(localized: "Scan", comment: "Voice Control name for the Scan NFC YubiKey button"),
         String(localized: "NFC", comment: "Voice Control name for the Scan NFC YubiKey button"),
         String(localized: "Scan YubiKey", comment: "Voice Control name for the Scan NFC YubiKey button")]
    }
    static var refresh: [String] {
        [String(localized: "Refresh", comment: "Mac toolbar"), String(localized: "Reload", comment: "Voice Control name for the Refresh button")]
    }
    static var calculate: [String] {
        [String(localized: "Calculate", comment: "Menu"), String(localized: "Refresh", comment: "Mac toolbar"),
         String(localized: "New code", comment: "Voice Control name for the Calculate button")]
    }
    static var copy: [String] {
        [String(localized: "Copy", comment: "Menu"), String(localized: "Copy code", comment: "Voice Control name for the Copy button")]
    }
    static var syncFromEnte: [String] {
        [String(localized: "Sync from Ente Auth", comment: "Main view menu item"), String(localized: "Sync", comment: "Voice Control name for the Sync from Ente Auth button"),
         String(localized: "Ente Auth", comment: "Ente sync navigation title")]
    }
    static var configuration: [String] {
        [String(localized: "Configuration"), String(localized: "Settings", comment: "Voice Control name for the Configuration button")]
    }
    static var about: [String] {
        [String(localized: "About"), String(localized: "Help", comment: "Smart card extension help button")]
    }
    static var enterManually: [String] {
        [String(localized: "Enter manually", comment: "Scan QR code add manually button"), String(localized: "Manual", comment: "Voice Control name for the Enter manually button"),
         String(localized: "Keyboard", comment: "Voice Control name for the Enter manually button, after its keyboard symbol")]
    }
}

extension View {
    /// Centers the view in the space it's given, and scrolls it instead when it's taller, e.g. at the largest text
    /// sizes or in landscape.
    func scrollsWhenTooTall() -> some View {
        GeometryReader { proxy in
            ScrollView {
                self.frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}
