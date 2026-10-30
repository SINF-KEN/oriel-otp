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

struct AboutView: View {
    
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            SettingsList {
                VStack(alignment: .center) {
                    Image(.icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 100, height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .padding(15)
                        .accessibilityHidden(true)
                    Text(verbatim: "Oriel OTP")
                        .scaledFont(.title)
                        .multilineTextAlignment(.center)
                    Text("\(Bundle.main.appVersion) (build \(Bundle.main.appBuildNumber))")
                        .scaledFont(.body)
                    AboutLanguageView()
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
                .padding(.horizontal, 20)
                .listRowBackground(Color.black.opacity(0))
                
                Section("Application") {
                    NavigationLink {
                        TutorialView()
                    } label: {
                        ListIconView(image: Image(systemName: "lightbulb"), color: Color(.systemOrange))
                        Text("How does it work")
                    }
                    .accessibilityIdentifier("about.tutorial")
                    NavigationLink {
                        VersionHistoryView(presentedFromMainView: false)
                            .navigationTitle(String(localized: "Version history", comment: "About navigation title"))
                    } label: {
                        ListIconView(image: Image(systemName: "list.clipboard"), color: Color(.systemGreen))
                        Text("Version history")
                    }
                    .accessibilityIdentifier("about.version-history")
                    #if os(iOS)
                    NavigationLink {
                        AppIconView()
                    } label: {
                        ListIconView(image: Image(systemName: "app.badge"), color: Color(.systemGreen), padding: 5)
                        Text("App icon")
                    }
                    .accessibilityIdentifier("about.app-icon")
                    #endif
                    Button {
                        Platform.open(URL(string: "https://github.com/SINF-KEN/oriel-otp/blob/main/LICENSE")!)
                    } label: {
                        HStack {
                            ListIconView(image: Image(systemName: "doc.text"), color: Color(.secondaryLabel))
                            Text("Terms of use")
                        }
                    }
                    Button {
                        Platform.open(URL(string: "https://github.com/SINF-KEN/oriel-otp/blob/main/PRIVACY.md")!)
                    } label: {
                        HStack {
                            ListIconView(image: Image(systemName: "person.badge.shield.checkmark"), color: Color(.secondaryLabel))
                            Text("Privacy policy")
                        }
                    }
                    NavigationLink {
                        LicensingView()
                    } label: {
                        HStack {
                            ListIconView(image: Image(systemName: "doc.text"), color: Color(.secondaryLabel))
                            Text("Licensing")
                        }
                    }
                }
                Section("Support") {
                    Button {
                        Platform.open(URL(string: "https://github.com/SINF-KEN/oriel-otp#readme")!)
                    } label: {
                        HStack {
                            ListIconView(image: Image(systemName: "book"), color: Color(.systemPink))
                            Text("User guide")
                        }
                    }
                    Button {
                        Platform.open(URL(string: "https://github.com/SINF-KEN/oriel-otp/blob/main/SUPPORT.md")!)
                    } label: {
                        HStack {
                            ListIconView(image: Image(systemName: "person.crop.circle.badge.questionmark"), color: Color(.systemRed), padding: 5)
                            Text("Contact support")
                        }
                    }
                }
            }
            #if os(macOS)
            // Rows, like on iOS, rather than bordered push buttons.
            .buttonStyle(.plain)
            #endif
            .navigationTitle(String(localized: "About", comment: "About navigation title"))
            #if os(iOS)
            // A window with its own close button on the Mac.
            .accessibilityAction(.escape) { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CloseButton { dismiss() }
                }
            }
            #endif
        }
    }
}

struct AboutLanguageView: View {
    
    var shouldShowLanguageNote: Bool {
        guard let langCode = Bundle.main.preferredLocalizations.first else { return false }
        return langCode.lowercased() == "sk"
    }
    
    var body: some View {
        if shouldShowLanguageNote {
            Text("This translation is a community effort. To suggest a correction, [open an issue on GitHub](https://github.com/SINF-KEN/oriel-otp/issues).")
                .multilineTextAlignment(.center)
                .scaledFont(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 15)
        } else {
            EmptyView()
        }
    }
    
}
