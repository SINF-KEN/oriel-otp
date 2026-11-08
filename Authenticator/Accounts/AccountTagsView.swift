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

/// Files an account under tags: the ones the other accounts have, and new ones.
struct AccountTagsView: View {

    @Environment(MainViewModel.self) private var model
    let account: Account
    @Binding var isPresented: Bool

    @State private var tags: [String]
    /// Tags added here, listed even after they're unchecked again.
    @State private var added: [String] = []
    @State private var newTag = ""
    @FocusState private var isNewTagFocused: Bool

    init(account: Account, isPresented: Binding<Bool>) {
        self.account = account
        _isPresented = isPresented
        _tags = State(initialValue: account.tags)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField(String(localized: "New tag", comment: "Tags sheet field"), text: $newTag)
                            .formRowTextBox()
                            .focused($isNewTagFocused)
                            .submitLabel(.done)
                            .onSubmit(addNewTag)
                            .accessibilityIdentifier("tags.new-tag")
                        Button(String(localized: "Add", comment: "Tags sheet button"), action: addNewTag)
                            .disabled(trimmedNewTag.isEmpty)
                    }
                }
                if !choices.isEmpty {
                    Section {
                        ForEach(choices, id: \.self) { tag in
                            let isSelected = contains(tag)
                            Button { toggle(tag) } label: {
                                HStack {
                                    Label(tag, systemImage: "tag")
                                        .foregroundStyle(Color.primary)
                                    Spacer()
                                    if isSelected {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                            .accessibilityHidden(true)
                                    }
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                        }
                    } footer: {
                        Text(footer)
                    }
                }
            }
            .formStyle(.grouped)
            .scaledButtonLabels()
            .navigationTitle(String(localized: "Tags", comment: "Tags sheet title"))
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
            .onAppear {
                // Straight to typing when there's nothing to choose from.
                if choices.isEmpty {
                    isNewTagFocused = true
                }
            }
        }
        #if os(macOS)
        .textScaledFrame(width: 380, height: 420)
        #endif
    }

    /// The tags of all accounts and the ones added here, by name.
    private var choices: [String] {
        EnteEntry.cleaned(model.allTags + account.tags + added)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var footer: String {
        switch account.location {
        case .ente: String(localized: "Tags are saved in Ente Auth, which shows them too.", comment: "Tags sheet footer for an Ente Auth account")
        case .device: String(localized: "Tags go along when the account moves to Ente Auth.", comment: "Tags sheet footer for an account on this device")
        case .yubiKey: String(localized: "A YubiKey has no room for tags, so they are kept on this device.", comment: "Tags sheet footer for a YubiKey account")
        }
    }

    private var trimmedNewTag: String {
        newTag.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func contains(_ tag: String) -> Bool {
        tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
    }

    private func toggle(_ tag: String) {
        if contains(tag) {
            tags.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame }
        } else {
            tags.append(tag)
        }
    }

    private func addNewTag() {
        let tag = trimmedNewTag
        guard !tag.isEmpty else { return }
        // An existing tag in another case is used as it is.
        let existing = choices.first { $0.caseInsensitiveCompare(tag) == .orderedSame } ?? tag
        if !contains(existing) {
            tags.append(existing)
        }
        added.append(existing)
        newTag = ""
    }

    private func save() {
        // What was typed counts, even without tapping Add.
        addNewTag()
        model.setTags(tags, of: account)
        isPresented = false
    }
}

/// The tags to show the accounts of, above the list once any account has a tag.
struct TagFilterBar: View {

    let tags: [String]
    @Binding var selection: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(String(localized: "All", comment: "Tag filter showing the accounts with any tag"), tag: nil)
                ForEach(tags, id: \.self) { tag in
                    chip(tag, tag: tag)
                }
            }
            .padding(.vertical, 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Tags", comment: "Tag filter, for VoiceOver"))
        .accessibilityIdentifier("accounts.tag-filter")
    }

    private func chip(_ title: String, tag: String?) -> some View {
        let isSelected = selection == tag
        return Button {
            selection = tag
        } label: {
            Text(title)
                .scaledFont(.subheadline) { $0.weight(isSelected ? .semibold : .regular) }
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                // The background's color on the accent, as white is unreadable on the light pink of dark mode.
                .foregroundStyle(isSelected ? Color(.systemBackground) : Color.primary)
                .background(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension Account {
    /// Whether the account is filed under the tag, nil for all accounts.
    func isTagged(_ tag: String?) -> Bool {
        guard let tag else { return true }
        return tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
    }
}
