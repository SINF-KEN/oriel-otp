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

extension View {
    /// Lets the Search Accounts command move the focus to the search field, which needs macOS 15.
    @ViewBuilder func searchFocusedIfAvailable(_ isFocused: Binding<Bool>) -> some View {
        if #available(macOS 15.0, *) {
            modifier(SearchFocusModifier(isFocused: isFocused))
        } else {
            self
        }
    }
}

@available(macOS 15.0, *)
private struct SearchFocusModifier: ViewModifier {
    @Binding var isFocused: Bool
    @FocusState private var focus: Bool

    func body(content: Content) -> some View {
        content
            .searchFocused($focus)
            .onChange(of: isFocused) { _, isFocused in
                if isFocused { focus = true }
            }
            .onChange(of: focus) { _, focus in
                isFocused = focus
            }
    }
}

#endif
