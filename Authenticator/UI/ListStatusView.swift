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

struct ListStatusView<Actions: View>: View {
    
    let image: Image
    let message: String
    let height: CGFloat
    /// Buttons for what to do next, shown below the message.
    @ViewBuilder let actions: Actions
    @State var showWhatsNew = false
    @ScaledSize(relativeTo: .largeTitle) private var imageSize: CGFloat = 100
    
    var body: some View {
        HStack {
            Spacer()
            VStack(spacing: 20) {
                Spacer()
                image
                    // Grows a little with the text, leaving the room to the message at the largest sizes.
                    .font(.system(size: min(imageSize, 140)))
                    .foregroundStyle(Color(.symbol))
                    .accessibilityHidden(true)
                Text(message)
                    .scaledFont(.title3)
                    .multilineTextAlignment(.center)
                    .padding(EdgeInsets(top: 0, leading: 30, bottom: 0, trailing: 30))
                // A button style other than plain, so each button gets its own taps rather than the whole row's.
                VStack(spacing: 12) {
                    actions
                }
                .buttonStyle(.bordered)
                Spacer()
                if SettingsConfig.showWhatsNewText {
                    WhatsNewView(showWhatsNew: $showWhatsNew)
                }
            }
            Spacer()
        }
        // A minimum rather than a fixed height, so the content isn't clipped when the list is short, e.g. in landscape on
        // a small iPhone or with the keyboard up, and never negative while the list is first laid out.
        .frame(minHeight: max(0, height - 100))
        .listRowSeparator(.hidden)
        .sheet(isPresented: $showWhatsNew) {
            NavigationStack {
                VersionHistoryView(presentedFromMainView: true)
                    .navigationTitle(String(localized: "What's new", comment: "About navigation title"))

            }
        }
    }
}

struct WhatsNewView: View {
    
    /// One sentence, so translators can put the link's words where their language needs them. The words between the
    /// asterisks are shown in the label color, the rest in the secondary color.
    var text: AttributedString {
        var text = AttributedString(localized: "See **what's new** in this version", comment: "Button below the account list. Keep the asterisks around the words that open the version history; they're shown brighter, not bold.")
        for run in text.runs {
            if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
                text[run.range].foregroundColor = .label
            } else {
                text[run.range].foregroundColor = .secondaryLabel
            }
            text[run.range].inlinePresentationIntent = nil
        }
        return text
    }
    
    @Binding var showWhatsNew: Bool

    var body: some View {
        Button {
            showWhatsNew.toggle()
        } label: {
            Text(text).scaledFont(.footnote)
        }
    }
}

#Preview {
    ListStatusView(image: Image(systemName: "figure.surfing"), message: "Gone surfing, will be back tomorrow", height: 300)
}

extension ListStatusView where Actions == EmptyView {
    init(image: Image, message: String, height: CGFloat) {
        self.init(image: image, message: message, height: height) { EmptyView() }
    }
}
