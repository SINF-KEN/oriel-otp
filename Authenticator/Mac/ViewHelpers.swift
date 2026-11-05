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

/// Tells its content whether the pointer is over it.
struct HoverReader<Content: View>: View {
    @ViewBuilder let content: (Bool) -> Content
    @State private var isHovering = false

    var body: some View {
        content(isHovering)
            .onHover { isHovering = $0 }
    }
}

/// Tells when the window around it starts and stops being resized by the user or an animation.
struct LiveResizeObserver: NSViewRepresentable {
    let onChange: (_ isResizing: Bool) -> Void

    func makeNSView(context: Context) -> ObserverView {
        ObserverView()
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.onChange = onChange
    }

    final class ObserverView: NSView {
        var onChange: ((Bool) -> Void)?

        override func viewWillStartLiveResize() {
            super.viewWillStartLiveResize()
            onChange?(true)
        }

        override func viewDidEndLiveResize() {
            super.viewDidEndLiveResize()
            // After the other views, which end their resize in the same pass.
            DispatchQueue.main.async { [weak self] in
                self?.onChange?(false)
            }
        }
    }
}

/// The search field above the list in the main window's single column. Escape clears it and leaves it, as in the
/// system's search field, and it grows with the text, which the system's doesn't.
struct SingleColumnSearchField: View {
    @Binding var text: String
    @Binding var isFocused: Bool
    @FocusState private var focus: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color(.secondaryLabel))
                .accessibilityHidden(true)
            TextField(String(localized: "Search"), text: $text)
                .textFieldStyle(.plain)
                .autocorrectionDisabled(true)
                .focused($focus)
                .accessibilityLabel(String(localized: "Search"))
                .accessibilityIdentifier("accounts.search")
                .onExitCommand {
                    text = ""
                    focus = false
                }
            if !text.isEmpty {
                Button(action: { text = "" }) {
                    Label(String(localized: "Clear search", comment: "Mac button in the search field above the account list"), systemImage: "xmark.circle.fill")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            }
        }
        .scaledBodyFont()
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(.secondarySystemBackground), in: Capsule())
        // A plain text field has no focus ring of its own.
        .overlay {
            Capsule()
                .strokeBorder(focus ? Color.accentColor : Color(.separator), lineWidth: focus ? 2 : 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onChange(of: isFocused) { _, isFocused in
            if isFocused { focus = true }
        }
        .onChange(of: focus) { _, focus in
            isFocused = focus
        }
    }
}

#endif
