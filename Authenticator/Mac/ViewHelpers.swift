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

/// Starts the scroller of the list it's behind below the section header, which stays at the top of the list while the
/// rows go under it. `contentMargins` for the scroll indicators does nothing for a list on the Mac.
struct ListScrollerInset: NSViewRepresentable {
    /// Whether the list's first row is a section's header.
    let hasSectionHeader: Bool

    func makeNSView(context: Context) -> InsetView {
        InsetView()
    }

    func updateNSView(_ view: InsetView, context: Context) {
        view.hasSectionHeader = hasSectionHeader
        view.scheduleUpdate()
    }

    final class InsetView: NSView {
        var hasSectionHeader = false
        private weak var table: NSTableView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleUpdate()
        }

        /// After the update or layout going on, as the scroller wouldn't move for an inset set during a layout. The
        /// table's frame changes with its rows, whose heights change with the text size, and the scroller's with the
        /// insets.
        @objc func scheduleUpdate() {
            DispatchQueue.main.async { [weak self] in
                self?.updateInset()
            }
        }

        private func updateInset() {
            guard let table = table ?? findTable(), let scrollView = table.enclosingScrollView else { return }
            let inset = hasSectionHeader && table.numberOfRows > 0 ? table.rect(ofRow: 0).height : 0
            if scrollView.scrollerInsets.top != inset {
                scrollView.scrollerInsets.top = inset
            }
        }

        /// The nearest table, which is the list's as this view is behind it.
        private func findTable() -> NSTableView? {
            var ancestor = superview
            while let view = ancestor {
                if let table = Self.table(in: view) {
                    self.table = table
                    // SwiftUI resets the insets when it updates the list, e.g. as the lock screen goes away, which
                    // moves the scroller.
                    for view in [table, table.enclosingScrollView?.verticalScroller].compactMap(\.self) as [NSView] {
                        NotificationCenter.default.addObserver(self, selector: #selector(scheduleUpdate),
                                                               name: NSView.frameDidChangeNotification, object: view)
                    }
                    return table
                }
                ancestor = view.superview
            }
            return nil
        }

        private static func table(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView {
                return table
            }
            return view.subviews.lazy.compactMap(table(in:)).first
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
