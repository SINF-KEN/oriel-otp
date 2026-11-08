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

/// An otpauth URL as Ente's apps store it: a JSON string.
private func rawData(_ url: String) -> String {
    String(decoding: try! JSONEncoder().encode(url), as: UTF8.self)
}

private let secret = "JBSWY3DPEHPK3PXP"

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

struct EnteTagsTests {

    @Test func readsTagsAndTheChosenIconFromTheURL() throws {
        let display = #"{"tags":["Work"," personal ","work",""],"iconSrc":"simpleIcon","iconID":"GitLab"}"#
        var components = try #require(URLComponents(string: "otpauth://totp/A:alice?secret=\(secret)"))
        components.queryItems?.append(URLQueryItem(name: "codeDisplay", value: display))
        let url = try #require(components.string)
        let entry = EnteEntry(rawData: rawData(url))
        // Without spaces around them, empty ones, or the same one twice.
        #expect(entry.tags == ["Work", "personal"])
        #expect(entry.iconID == "GitLab")
    }

    @Test func readsTagsFromTheObjectFormat() {
        let object = #"{"rawData":"otpauth://totp/A:alice?secret=JBSWY3DPEHPK3PXP","display":{"tags":["work"]}}"#
        #expect(EnteEntry(rawData: object).tags == ["work"])
        #expect(EnteCloudCode(rawData: object)?.tags == ["work"])
    }

    @Test func savesTagsLikeEnteAuthAndKeepsTheRest() throws {
        let object = #"{"rawData":"otpauth://totp/A:alice?secret=JBSWY3DPEHPK3PXP","display":{"note":"In the safe","pinned":true}}"#
        var editor = try #require(EnteEntryEditor(rawData: object))
        #expect(editor.tags.isEmpty)
        editor.tags = ["work", " Work", "banking"]
        let edited = try #require(editor.rawData)
        let entry = EnteEntry(rawData: edited)
        #expect(entry.tags == ["work", "banking"])
        #expect(entry.isPinned)
        let components = try #require(entry.components)
        let display = try #require(components.queryItems?.first { $0.name == "codeDisplay" }?.value)
        let settings = try #require(try JSONSerialization.jsonObject(with: Data(display.utf8)) as? [String: Any])
        #expect(settings["tags"] as? [String] == ["work", "banking"])
        #expect(settings["note"] as? String == "In the safe")
    }

    @Test func tagsDontMakeItAnotherAccount() throws {
        let plain = try #require(EnteCloudCode(rawData: rawData("otpauth://totp/A:alice?secret=\(secret)")))
        var editor = try #require(EnteEntryEditor(rawData: rawData("otpauth://totp/A:alice?secret=\(secret)")))
        editor.tags = ["work"]
        let edited = try #require(editor.rawData)
        let tagged = try #require(EnteCloudCode(rawData: edited))
        #expect(tagged.tags == ["work"])
        #expect(plain.isSameAccount(as: tagged))
    }
}

@MainActor struct AccountTagsTests {

    private func template(_ issuer: String) throws -> YubiKitOATHSession.CredentialTemplate {
        let url = try #require(URL(string: "otpauth://totp/\(issuer):alice?secret=\(secret)&issuer=\(issuer)"))
        return try YubiKitOATHSession.CredentialTemplate(otpauthURL: url)
    }

    private func signedOutCloud() -> EnteCloud {
        let defaults = makeTestDefaults()
        return EnteCloud(store: EnteSessionStore(keychain: InMemoryKeychain(), defaults: defaults, canSave: true), storage: InMemoryVaultStorage(),
                         session: OfflineURLProtocol.session, watch: WatchAccountSync(defaults: defaults))
    }

    @Test func tagsOfAnAccountOnThisDeviceAreSavedWithIt() throws {
        let storage = MemoryDeviceStorage()
        let device = DeviceAccounts(storage: storage)
        let model = MainViewModel(cloud: signedOutCloud(), device: device)
        _ = try model.addDeviceAccount(template("GitHub"))
        _ = try model.addDeviceAccount(template("GitLab"))
        let github = try #require(model.accounts.first { $0.title == "GitHub" })

        model.setTags(["work", " Work ", "open source"], of: github)
        #expect(github.tags == ["work", "open source"])
        #expect(model.allTags == ["open source", "work"])
        #expect(github.isTagged("WORK"))
        #expect(!github.isTagged("banking"))
        #expect(github.isTagged(nil))

        // In the account's own data, so they go along to Ente Auth, and they're there after a relaunch.
        #expect(DeviceAccounts(storage: storage).accounts.first { $0.code.issuer == "GitHub" }?.code.tags == ["work", "open source"])
        let relaunched = MainViewModel(cloud: signedOutCloud(), device: DeviceAccounts(storage: storage))
        #expect(relaunched.accounts.first { $0.title == "GitHub" }?.tags == ["work", "open source"])
        #expect(relaunched.allTags == ["open source", "work"])

        model.setTags([], of: github)
        #expect(model.allTags.isEmpty)
    }

    @Test func keepsYubiKeyTagsInAnEncryptedFile() throws {
        let url = FileManager.default.temporaryDirectory.appending(components: UUID().uuidString, "Tags")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let key = InMemoryVaultKey()
        let storage = AccountTagsStorage(url: url, keychain: key)
        #expect(storage.read() == [:])
        try storage.save(["GitHub:alice": ["work"], "GitLab:alice": []])
        // Accounts without tags aren't kept.
        #expect(AccountTagsStorage(url: url, keychain: key).read() == ["GitHub:alice": ["work"]])
        let data = try Data(contentsOf: url)
        #expect(data.range(of: Data("GitHub".utf8)) == nil)
    }

    @Test func serviceIconsFollowARename() throws {
        let device = DeviceAccounts(storage: MemoryDeviceStorage())
        let model = MainViewModel(cloud: signedOutCloud(), device: device)
        _ = try model.addDeviceAccount(template("Unknown"))
        #expect(model.accounts.first?.serviceIcon == nil)
        let account = try #require(model.accounts.first)
        model.renameAccount(account, issuer: "GitHub", accountName: "alice") {}
        #expect(model.accounts.first?.serviceIcon?.slug == "github")
    }
}
