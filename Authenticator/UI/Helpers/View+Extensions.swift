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

extension Animation {
    /// The default animation, or none with Reduce Motion on, so buttons and rows appear and go without sliding.
    @MainActor static var unlessReduceMotion: Animation? {
        Platform.prefersReducedMotion ? nil : .default
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

// Larger Text on the Mac. macOS doesn't let apps follow a system text size, and SwiftUI's text styles and
// @ScaledMetric don't change with dynamicTypeSize there, so the Mac app has its own text size (View > Make Text
// Bigger) and scales its fonts and sizes by it. On iOS these are the system's text styles and @ScaledMetric.
extension EnvironmentValues {
    /// How much larger than the system's size the Mac shows text, from 1 to 2. Always 1 on iOS.
    @Entry var textScale: CGFloat = 1
}

extension Font {
    /// The text style, grown by the Mac's text size.
    static func scaled(_ style: TextStyle, by scale: CGFloat) -> Font {
        #if os(macOS)
        guard scale != 1 else { return .system(style) }
        let size = NSFont.preferredFont(forTextStyle: style.nsTextStyle).pointSize * scale
        // The Mac's headline is the body size in bold.
        return .system(size: size, weight: style == .headline ? .bold : .regular)
        #else
        .system(style)
        #endif
    }
}

extension View {
    /// Sets the font to a text style that also grows with the Mac's text size; use it rather than `font(.body)` in
    /// views the Mac shows. `modify` changes the font further, e.g. `{ $0.weight(.medium) }`.
    func scaledFont(_ style: Font.TextStyle, _ modify: @escaping (Font) -> Font = { $0 }) -> some View {
        modifier(ScaledFontModifier(style: style, modify: modify))
    }
}

extension View {
    /// The body font at the Mac's text size, for text without a font of its own: list rows, form labels, buttons and
    /// text fields. Left to the system at 100% and on iOS.
    func scaledBodyFont() -> some View {
        modifier(ScaledBodyFontModifier())
    }
}

private struct ScaledBodyFontModifier: ViewModifier {
    @Environment(\.textScale) private var textScale

    func body(content: Content) -> some View {
        #if os(macOS)
        content.font(textScale == 1 ? nil : .scaled(.body, by: textScale))
        #else
        content
        #endif
    }
}

extension View {
    /// Shows the buttons in a form at the Mac's text size. A Mac button keeps the system's font unless its label sets
    /// one, so this sets it in each label. Put it on the form itself rather than above its toolbar, whose buttons keep
    /// their size and style.
    func scaledButtonLabels() -> some View {
        modifier(ScaledButtonLabelsModifier())
    }
}

private struct ScaledButtonLabelsModifier: ViewModifier {
    @Environment(\.textScale) private var textScale

    @ViewBuilder func body(content: Content) -> some View {
        #if os(macOS)
        if textScale != 1 {
            content.buttonStyle(ScaledLabelButtonStyle())
        } else {
            content
        }
        #else
        content
        #endif
    }
}

#if os(macOS)
/// The standard button, with the label at the Mac's text size.
private struct ScaledLabelButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) {
            configuration.label.scaledBodyFont()
        }
        .buttonStyle(.automatic)
    }
}
#endif

private struct ScaledFontModifier: ViewModifier {
    @Environment(\.textScale) private var textScale
    let style: Font.TextStyle
    let modify: (Font) -> Font

    func body(content: Content) -> some View {
        content.font(modify(.scaled(style, by: textScale)))
    }
}

extension View {
    /// A window's or sheet's size that grows with the Mac's text size, so larger text gets more room instead of
    /// wrapping in a narrow column, up to the size of the screen. The same as `frame(width:height:)` on iOS.
    func textScaledFrame(width: CGFloat? = nil, height: CGFloat? = nil) -> some View {
        modifier(TextScaledFrameModifier(width: width, height: height))
    }

    /// The flexible `frame(minWidth:idealWidth:minHeight:idealHeight:)`, growing with the Mac's text size.
    func textScaledFrame(minWidth: CGFloat, idealWidth: CGFloat? = nil, minHeight: CGFloat, idealHeight: CGFloat? = nil) -> some View {
        modifier(TextScaledFrameModifier(minWidth: minWidth, idealWidth: idealWidth, minHeight: minHeight, idealHeight: idealHeight))
    }
}

private struct TextScaledFrameModifier: ViewModifier {
    @Environment(\.textScale) private var textScale
    var width: CGFloat?
    var height: CGFloat?
    var minWidth: CGFloat?
    var idealWidth: CGFloat?
    var minHeight: CGFloat?
    var idealHeight: CGFloat?

    func body(content: Content) -> some View {
        if minWidth != nil || minHeight != nil {
            content.frame(minWidth: scaled(minWidth, \.width), idealWidth: scaled(idealWidth, \.width),
                          minHeight: scaled(minHeight, \.height), idealHeight: scaled(idealHeight, \.height))
        } else {
            content.frame(width: scaled(width, \.width), height: scaled(height, \.height))
        }
    }

    private func scaled(_ size: CGFloat?, _ dimension: KeyPath<CGSize, CGFloat>) -> CGFloat? {
        guard let size, textScale != 1 else { return size }
        #if os(macOS)
        // Leaves room for the menu bar, the Dock and the window's title bar.
        let screen = (NSScreen.main?.visibleFrame.size ?? CGSize(width: 1280, height: 800))[keyPath: dimension] - 80
        return max(size, min(size * textScale, screen))
        #else
        return size
        #endif
    }
}

/// A list of settings: a list on iOS, and on the Mac a grouped form, like the Settings window's General tab. A Mac
/// list sets the system's font on the text in each row, so its rows wouldn't follow the app's text size.
struct SettingsList<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        #if os(macOS)
        Form { content }
            .formStyle(.grouped)
            .scaledButtonLabels()
        #else
        List { content }
        #endif
    }
}

#if os(macOS)
/// A size that grows with the Mac's text size, like `@ScaledMetric` does with Dynamic Type on iOS.
@propertyWrapper struct ScaledSize: DynamicProperty {
    @Environment(\.textScale) private var textScale
    private let size: CGFloat

    init(wrappedValue: CGFloat, relativeTo textStyle: Font.TextStyle = .body) {
        size = wrappedValue
    }

    var wrappedValue: CGFloat { size * textScale }
}

private extension Font.TextStyle {
    var nsTextStyle: NSFont.TextStyle {
        switch self {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        default: .body
        }
    }
}
#else
/// `@ScaledMetric`, which on the Mac is a size that grows with the app's own text size instead.
typealias ScaledSize = ScaledMetric<CGFloat>
#endif
