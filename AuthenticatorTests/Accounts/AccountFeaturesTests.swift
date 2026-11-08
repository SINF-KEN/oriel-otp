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

import CryptoKit
import Foundation
import Testing
import YubiKit

@testable import OrielOTP

struct ServiceIconTests {

    @Test func findsTheBrandOfTheIssuer() {
        #expect(ServiceIcon.icon(issuer: "GitHub", accountName: "alice")?.slug == "github")
        // Case, accents, spaces and punctuation don't matter.
        #expect(ServiceIcon.icon(issuer: "  github ", accountName: "alice")?.slug == "github")
        #expect(ServiceIcon.icon(issuer: "Proton Mail", accountName: "alice")?.slug == ServiceIcon.icon(issuer: "protonmail", accountName: "")?.slug)
    }

    @Test func findsTheBrandOfADomainOrAFirstWord() {
        #expect(ServiceIcon.icon(issuer: "github.com", accountName: "alice")?.slug == "github")
        #expect(ServiceIcon.icon(issuer: "accounts.google.com", accountName: "alice")?.slug == "google")
        #expect(ServiceIcon.icon(issuer: "Google Workspace", accountName: "alice")?.slug == "google")
        #expect(ServiceIcon.icon(issuer: "GitHub (work)", accountName: "alice")?.slug == "github")
    }

    @Test func doesntGuessFromAnEmailAddressOrAShortWord() {
        // A Gmail address can be the name of any account.
        #expect(ServiceIcon.icon(issuer: nil, accountName: "alice@gmail.com") == nil)
        #expect(ServiceIcon.icon(issuer: "", accountName: "alice@gmail.com") == nil)
        #expect(ServiceIcon.icon(issuer: "My Bank", accountName: "alice") == nil)
        #expect(ServiceIcon.icon(issuer: "Some company nobody knows", accountName: "alice") == nil)
    }

    @Test func usesTheAccountNameWithoutAnIssuer() {
        #expect(ServiceIcon.icon(issuer: nil, accountName: "GitHub")?.slug == "github")
    }

    @Test func prefersTheIconChosenInEnteAuth() {
        #expect(ServiceIcon.icon(issuer: "My Git server", accountName: "alice", iconID: "GitLab")?.slug == "gitlab")
        // One the app doesn't have falls back to the issuer's.
        #expect(ServiceIcon.icon(issuer: "GitHub", accountName: "alice", iconID: "nothing-like-this")?.slug == "github")
    }

    @Test func everyIconIsInTheAssetCatalog() throws {
        let catalog = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(components: "Authenticator", "Assets.xcassets", "ServiceIcons")
        for icon in ServiceIcon.catalog {
            let svg = catalog.appending(components: "\(icon.slug).imageset", "\(icon.slug).svg")
            #expect(FileManager.default.fileExists(atPath: svg.path), "\(icon.slug)")
        }
        #expect(ServiceIcon.catalog.count > 250)
    }

    @Test func drawsTheIconInTheColorThatStandsOut() throws {
        let dark = ServiceIcon(slug: "x", color: 0x181717, names: [])
        let light = ServiceIcon(slug: "x", color: 0xFFFC00, names: [])
        #expect(!dark.usesDarkForeground)
        #expect(light.usesDarkForeground)
    }
}
