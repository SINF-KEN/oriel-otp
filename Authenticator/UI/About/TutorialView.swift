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

struct TutorialView: View {

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State var page: Int = 0
    
    var body: some View {
        NavigationStack {
            #if os(iOS)
            TabView(selection: $page) {
                ForEach(Array(self.tutorialPages.enumerated()), id: \.element) { index, tutorialPage in
                    pageView(tutorialPage).tag(index)
                }
            }
            #else
            // A Mac has no swipeable pages, so one page shows at a time, with Back and Next.
            pageView(tutorialPages[page])
                .id(page)
                .transition(.opacity)
            #endif
        }
        #if os(iOS)
        .onAppear() {
            // Page indicator is white in light mode and is not visible on white background.
            UIPageControl.appearance().currentPageIndicatorTintColor = .label
            UIPageControl.appearance().pageIndicatorTintColor = .secondaryLabel
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        #endif
        .toolbar {
            #if os(macOS)
            ToolbarItem(placement: .navigation) {
                Button {
                    // Swapped at once with Reduce Motion, rather than sliding.
                    withAnimation(reduceMotion ? nil : .default) {
                        page -= 1
                    }
                } label: {
                    Label(String(localized: "Back", comment: "Mac tutorial button"), systemImage: "chevron.backward")
                }
                .disabled(page == 0)
            }
            #endif
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation(reduceMotion ? nil : .default) {
                        page += 1
                    }
                } label: {
                    Label("Next", systemImage: "chevron.forward")
                }
                .disabled(page >= self.tutorialPages.count - 1)
            }
        }
    }

    private func pageView(_ tutorialPage: TutorialPageModel) -> some View {
        ScrollView {
            VStack {
                Text(tutorialPage.title)
                    .multilineTextAlignment(.center)
                    .font(.title)
                    .bold()
                    .accessibilityAddTraits(.isHeader)
                // The drawings are larger than the screen, so they're scaled down to fit.
                tutorialPage.image
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 220)
                    .padding(30)
                    .accessibilityHidden(true)
                Text(tutorialPage.text)
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                tutorialPage.link.map { link in
                    Button {
                        Platform.open(link)
                    } label: {
                        Text("Read more...").bold()
                    }
                    .padding(.top, 30)
                }
                Spacer()
            }
            .padding(30)
        }
    }
}

struct TutorialPageModel: Hashable, Identifiable {
    var id: Int { self.hashValue }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(title)
        hasher.combine(text)
        hasher.combine(link)
    }
    
    let title: String
    let image: Image
    let text: String
    let link: URL?
}

extension TutorialView {
    var tutorialPages: [TutorialPageModel] {
        #if os(macOS)
        // A Mac connects to a YubiKey over USB only.
        [TutorialPageModel(title: String(localized: "How it works"),
                           image: Image(.tutorialAccounts),
                           text: String(localized: "Get a shared secret from any service you wish to secure, store it on the YubiKey and use it to generate your security codes.\n\nYou will need a YubiKey with a USB-C or USB-A connector to get started.", comment: "Mac tutorial"),
                           link: nil),

         TutorialPageModel(title: String(localized: "Add accounts from Ente Auth", comment: "Tutorial page title"),
                           image: Image(.tutorialEnteSync),
                           text: String(localized: "Already use Ente Auth? Choose File > Sync from Ente Auth, sign in and pick the accounts to add to your YubiKey.\n\nWith Stay signed in, your Ente Auth accounts are listed here too, and changes you make are saved in Ente Auth. Your Ente Auth data is decrypted on this Mac.", comment: "Mac tutorial"),
                           link: nil),

         TutorialPageModel(title: String(localized: "Plug in your YubiKey"),
                           image: Image(.tutorialPlugIn),
                           text: String(localized: "Plug your YubiKey into your Mac, directly or through a USB hub or adapter.\n\nTouch the YubiKey when prompted.", comment: "Mac tutorial"),
                           link: nil),

         TutorialPageModel(title: String(localized: "Where to get QR codes"),
                           image: Image(.tutorialQrCode),
                           text: String(localized: "QR codes are available from the services you wish to secure.\n\nWhen you add an account, Oriel OTP can find the QR code on your screen, read a copied or dropped picture of it, or take one with your iPhone.", comment: "Mac tutorial"),
                           link: nil)
        ]
        #else
        [TutorialPageModel(title: String(localized: "How it works"),
                           image: Image(.tutorialAccounts),
                           text: String(localized: "Get a shared secret from any service you wish to secure, store it on the YubiKey and use it to generate your security codes.\n\nYou will need a YubiKey with NFC or USB-C to get started."),
                           link: nil),

         TutorialPageModel(title: String(localized: "Add accounts from Ente Auth", comment: "Tutorial page title"),
                           image: Image(.tutorialEnteSync),
                           text: String(localized: "Already use Ente Auth? Choose Sync from Ente Auth in the account list menu, sign in and pick the accounts to add to your YubiKey.\n\nWith Stay signed in, your Ente Auth accounts are listed here too, and changes you make are saved in Ente Auth. Your Ente Auth data is decrypted on this device.", comment: "Tutorial"),
                           link: nil),
        
         TutorialPageModel(title: String(localized: "Plug in your YubiKey"),
                           image: Image(.tutorialPlugIn),
                            text: String(localized: "If your YubiKey has a USB-C connector, plug it in.\n\nTouch the YubiKey when prompted."),
                            link: nil),
        
         TutorialPageModel(title: String(localized: "Scan your YubiKey over NFC"),
                           image: Image(.tutorialNfc),
                            text: String(localized: "If you have a YubiKey with NFC, pull down the main view to activate NFC.\n\nHold the key horizontally and tilt the iPhone towards the key.\n\nTouch the center of the key to the edge of the phone."),
                            link: nil),
         
         TutorialPageModel(title: String(localized: "Where to get QR codes"),
                           image: Image(.tutorialQrCode),
                            text: String(localized: "QR codes are available from the services you wish to secure.\n\nSimply scan the QR code when you add your YubiKey and generate your own security codes."),
                            link: nil)
        ]
        #endif
    }
}
