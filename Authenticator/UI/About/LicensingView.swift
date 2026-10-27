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

struct LicensingView: View {
    var body: some View {
        List {
            Text(self.licensingText())
                .font(.footnote)
        }
        .navigationTitle("Licensing")
    }
}

extension LicensingView {
    private func licensingText() -> AttributedString {
        guard let url = Bundle.main.url(forResource: "Licensing", withExtension: "md"),
              let licensingMarkdown = try? String(contentsOf: url, encoding: .utf8) else { return AttributedString() }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        // Show the plain text rather than nothing if the markdown can't be parsed.
        return (try? AttributedString(markdown: licensingMarkdown, options: options)) ?? AttributedString(licensingMarkdown)
    }
}
