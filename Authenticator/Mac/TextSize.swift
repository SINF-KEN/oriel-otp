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

/// The Mac app's text size, from 100% to 200% of the system's. macOS has no text size that apps can follow, so the
/// app has its own, in View > Make Text Bigger and Smaller (⌘+, ⌘−, ⌘0) and in Settings > General.
enum TextSize {
    static let key = "Mac.TextSize"
    static let steps: [Double] = [1, 1.25, 1.5, 1.75, 2]

    static func bigger(than scale: Double) -> Double? { steps.first { $0 > scale + 0.01 } }
    static func smaller(than scale: Double) -> Double? { steps.last { $0 < scale - 0.01 } }
}

extension View {
    /// Shows the window's text at the app's text size. Every window and the menu bar extra have it. The main window
    /// sets the body font and control size further in (`scalesContent: false`), with `scaledBodyFont()` below its
    /// toolbar and search field, which keep the system's size.
    func appTextSize(scalesContent: Bool = true) -> some View {
        modifier(AppTextSizeModifier(scalesContent: scalesContent))
    }

    /// Switches, checkboxes and buttons grow a little with the text, from 150%. Not set above a toolbar: any control
    /// size there, the large one as much as the regular one, also reaches the toolbar's buttons and squeezes them from
    /// circles into narrow pills with small icons.
    @ViewBuilder func textScaledControlSize(_ scale: Double) -> some View {
        if scale >= 1.5 {
            controlSize(.large)
        } else {
            self
        }
    }
}

private struct AppTextSizeModifier: ViewModifier {
    @AppStorage(TextSize.key) private var scale = 1.0
    let scalesContent: Bool

    @ViewBuilder func body(content: Content) -> some View {
        let content = content
            .font(scalesContent && scale != 1 ? .scaled(.body, by: scale) : nil)
            // On the Mac, layouts follow the room there is at this size rather than the accessibility sizes: windows
            // and the sidebar grow with the text, and the main window's columns become one when they no longer fit.
            .environment(\.textScale, scale)
        if scalesContent {
            content.textScaledControlSize(scale)
        } else {
            content
        }
    }
}

/// View > Make Text Bigger, Make Text Smaller and Actual Size.
struct TextSizeCommands: Commands {
    @AppStorage(TextSize.key) private var scale = 1.0

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Divider()
            Button(String(localized: "Make Text Bigger", comment: "Mac View menu")) {
                if let bigger = TextSize.bigger(than: scale) { scale = bigger }
            }
            .keyboardShortcut("+")
            .disabled(TextSize.bigger(than: scale) == nil)
            Button(String(localized: "Make Text Smaller", comment: "Mac View menu")) {
                if let smaller = TextSize.smaller(than: scale) { scale = smaller }
            }
            .keyboardShortcut("-")
            .disabled(TextSize.smaller(than: scale) == nil)
            Button(String(localized: "Actual Size", comment: "Mac View menu, back to the normal text size")) {
                scale = 1
            }
            .keyboardShortcut("0")
            .disabled(scale == 1)
            Divider()
        }
    }
}

/// The text size in Settings > General.
struct TextSizePicker: View {
    @AppStorage(TextSize.key) private var scale = 1.0

    var body: some View {
        Picker(String(localized: "Text size", comment: "Mac setting"), selection: $scale) {
            ForEach(TextSize.steps, id: \.self) { step in
                Text(step.formatted(.percent))
                    .scaledBodyFont()
            }
        }
    }
}

#endif
