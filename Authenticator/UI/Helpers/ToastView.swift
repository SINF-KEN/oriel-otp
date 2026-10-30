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

struct ToastView: View {
    
    let message: String
    
    @State var isVisible = true
    
    var body: some View {
        #if os(macOS)
        // A small banner at the bottom of the window, like the Mac's own status messages.
        Text(message)
            .font(.callout)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color(.separator)))
            .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
            .padding()
        #else
        ZStack(alignment: .leading) {
            Text(message)
                .font(.body)
                .multilineTextAlignment(.center)
                // YubiBlue is a light green in dark mode, so white text would lose its contrast there.
                .foregroundStyle(Color(.systemBackground))
                // Wraps onto more lines instead of running off a narrow screen or at large text sizes.
                .fixedSize(horizontal: false, vertical: true)
                .padding(EdgeInsets(top: 5, leading: 15, bottom: 5, trailing: 15))
                .background(Color(.yubiBlue))
                .clipShape(.rect(cornerRadius: 20))
                .shadow(radius: 5)
        }
        .padding(.horizontal)
        #endif
    }
}

struct ToastModifier: ViewModifier {

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var isPresenting: Bool
    var message: String
    
    @ViewBuilder public func main() -> some View {
        if isPresenting {
            ToastView(message: message)
                .onTapGesture {
                    isPresenting = false
                }
                // Fades in and out without growing with Reduce Motion.
                .transition(reduceMotion ? .opacity : AnyTransition.scale(scale: 0.8).combined(with: .opacity))
        }
    }
    
    @ViewBuilder public func body(content: Content) -> some View {
        #if os(macOS)
        let alignment = Alignment.bottom
        #else
        let alignment = Alignment.top
        #endif
        content
            .overlay(alignment: alignment) {
                // In the largest region clear of the fold, so a toast isn't split across the halves of an iPhone Duo.
                main()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
                    .avoidingReservedRegions()
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(), value: isPresenting)
    }
}

public extension View {
    
    func toast(isPresenting: Binding<Bool>, message: String) -> some View {
        modifier(ToastModifier(isPresenting: isPresenting, message: message))
    }
    
}
