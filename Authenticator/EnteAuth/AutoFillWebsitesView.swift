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

/// The websites an Ente Auth account's codes are suggested on by AutoFill.
struct AutoFillWebsitesView: View {

    private struct Website: Identifiable {
        let id = UUID()
        var text: String
    }

    let id: String
    let issuer: String?
    @Binding var isPresented: Bool

    private var autoFill: AutoFillAccountSync { .shared }
    @State private var websites: [Website]
    @State private var invalidWebsite: String?

    init(id: String, issuer: String?, isPresented: Binding<Bool>) {
        self.id = id
        self.issuer = issuer
        _isPresented = isPresented
        _websites = State(initialValue: AutoFillAccountSync.shared.websites(for: id, issuer: issuer).map { Website(text: $0) })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach($websites) { $website in
                        // Boxed on iOS too: with no placeholder, a new row would otherwise look like nothing was added.
                        TextField(
                            String(localized: "Website", comment: "AutoFill website field, for VoiceOver"), text: $website.text,
                            prompt: Text(verbatim: "")
                        )
                        .formRowTextBox()
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .environment(\.layoutDirection, .leftToRight)
                    }
                    .onDelete { websites.remove(atOffsets: $0) }
                    Button(String(localized: "Add website", comment: "AutoFill websites button")) {
                        websites.append(Website(text: ""))
                    }
                } footer: {
                    Text(
                        String(
                            localized:
                                "AutoFill suggests this account's code on these websites and their subdomains. Without a website, choose the code from the list of codes instead.",
                            comment: "AutoFill websites footer"))
                }
                if let suggestion = AutoFillWebsites.suggestion(issuer: issuer),
                    !websites.contains(where: { AutoFillWebsites.normalized($0.text) == suggestion })
                {
                    // Made up from the account's name, so it is only used once the user adds it.
                    Section {
                        Button(
                            String(
                                localized: "Add \(suggestion)",
                                comment:
                                    "AutoFill websites button. The placeholder is a website made up from the account's name, e.g. mastodon.com."
                            )
                        ) {
                            websites.append(Website(text: suggestion))
                        }
                    } footer: {
                        Text(
                            String(
                                localized:
                                    "Add it only if it's where you sign in to this account. Codes aren't suggested on a website until you add it.",
                                comment: "AutoFill websites footer below a website made up from the account's name"))
                    }
                }
                if autoFill.hasChosenWebsites(for: id) {
                    let guessed = AutoFillWebsites.guess(issuer: issuer)
                    Section {
                        Button(String(localized: "Use suggested websites", comment: "AutoFill websites button")) {
                            autoFill.setWebsites(nil, for: id)
                            isPresented = false
                        }
                    } footer: {
                        if !guessed.isEmpty {
                            Text(verbatim: guessed.joined(separator: ", "))
                                .environment(\.layoutDirection, .leftToRight)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scaledButtonLabels()
            .navigationTitle(String(localized: "AutoFill websites", comment: "AutoFill websites navigation title"))
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityAction(.escape) { isPresented = false }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CancelButton { isPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    ConfirmButton(String(localized: "Save")) { save() }
                }
            }
            .alert(
                String(localized: "Not a website", comment: "AutoFill websites alert"),
                isPresented: Binding(get: { invalidWebsite != nil }, set: { if !$0 { invalidWebsite = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(
                    String(
                        localized: "Enter a domain such as example.com instead of “\(invalidWebsite ?? "")”.",
                        comment: "AutoFill websites alert. The placeholder is what was typed."))
            }
        }
    }

    private func save() {
        var chosen = [String]()
        for website in websites.map({ $0.text.trimmingCharacters(in: .whitespaces) }) where !website.isEmpty {
            guard let normalized = AutoFillWebsites.normalized(website) else {
                invalidWebsite = website
                return
            }
            if !chosen.contains(normalized) { chosen.append(normalized) }
        }
        autoFill.setWebsites(chosen == AutoFillWebsites.guess(issuer: issuer) ? nil : chosen, for: id)
        isPresented = false
    }
}
