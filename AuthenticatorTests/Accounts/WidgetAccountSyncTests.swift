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

#if os(iOS)
    import Foundation
    import Testing

    @testable import OrielOTP

    @MainActor
    struct WidgetAccountSyncTests {

        private let url = URL.temporaryDirectory.appending(components: "WidgetAccountSyncTests-\(UUID().uuidString)", "Accounts")
        private let keychain = InMemoryVaultKey()
        private let defaults = UserDefaults(suiteName: "WidgetAccountSyncTests-\(UUID().uuidString)")!

        private var file: WidgetAccountsFile { WidgetAccountsFile(url: url, keychain: keychain) }

        private static let account = OTPAccount(
            id: "ente/1", kind: .totp, issuer: "GitHub", accountName: "alice", secret: Data("s".utf8),
            algorithm: .sha1, digits: 6, period: 30, isPinned: true)

        @Test func writesNothingUntilTurnedOn() throws {
            let sync = WidgetAccountSync(storage: file, defaults: defaults)
            sync.update([Self.account])
            #expect(try file.load() == nil)
            sync.isEnabled = true
            #expect(try file.load() == [Self.account])
        }

        @Test func turningItOffDeletesTheAccounts() throws {
            let sync = WidgetAccountSync(storage: file, defaults: defaults)
            sync.isEnabled = true
            sync.update([Self.account])
            sync.isEnabled = false
            #expect(try file.load() == nil)
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }

        @Test func unpinningTheLastAccountDeletesTheFile() throws {
            let sync = WidgetAccountSync(storage: file, defaults: defaults)
            sync.isEnabled = true
            sync.update([Self.account])
            sync.update([])
            #expect(try file.load() == nil)
        }
    }
#endif
