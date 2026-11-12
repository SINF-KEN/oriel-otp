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

@testable import OrielOTP

@MainActor
struct AccountUsageTests {

    private let url = URL.temporaryDirectory.appending(components: "AccountUsageTests-\(UUID().uuidString)", "Counts")
    private let keychain = InMemoryVaultKey()
    private let defaults = UserDefaults(suiteName: "AccountUsageTests-\(UUID().uuidString)")!

    private func usage(keychain: EncryptedFileKey? = nil) -> AccountUsage {
        AccountUsage(url: url, keychain: keychain ?? self.keychain, defaults: defaults)
    }

    private nonisolated struct LockedKey: EncryptedFileKey {
        func existingKey() throws -> SymmetricKey? { throw EncryptedFileError.unavailable }
        func createKey() throws -> SymmetricKey { throw EncryptedFileError.unavailable }
        func removeKey() {}
    }

    @Test func countsNothingWhileOff() {
        let usage = usage()
        usage.recordUse(of: "ente/1")
        #expect(usage.count(for: "ente/1") == 0)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(usage.ordered(["a", "b"], id: { $0 }) == ["a", "b"])
    }

    @Test func putsTheMostUsedFirstAndKeepsTheOrderOfTies() {
        let usage = usage()
        usage.isEnabled = true
        usage.recordUse(of: "c")
        usage.recordUse(of: "c")
        usage.recordUse(of: "b")
        usage.recordUse(of: "d")
        #expect(usage.ordered(["a", "b", "c", "d", "e"], id: { $0 }) == ["c", "b", "d", "a", "e"])
    }

    @Test func keepsTheCountsOnThisDevice() {
        let first = usage()
        first.isEnabled = true
        first.recordUse(of: "device/1")
        first.recordUse(of: "device/1")
        let second = usage()
        #expect(second.isEnabled)
        #expect(second.count(for: "device/1") == 2)
        // Encrypted: the account's name isn't in the file.
        let data = try? Data(contentsOf: url)
        #expect(data != nil)
        #expect(data.map { !String(decoding: $0, as: UTF8.self).contains("device/1") } == true)
    }

    @Test func turningItOffDeletesTheCounts() {
        let usage = usage()
        usage.isEnabled = true
        usage.recordUse(of: "ente/1")
        usage.isEnabled = false
        #expect(!FileManager.default.fileExists(atPath: url.path))
        usage.isEnabled = true
        #expect(usage.count(for: "ente/1") == 0)
        #expect(self.usage().count(for: "ente/1") == 0)
    }

    /// While the device is locked the counts can't be read, so a copy then isn't counted rather than replacing them.
    @Test func countsNothingWhileTheDeviceIsLocked() {
        let unlocked = usage()
        unlocked.isEnabled = true
        unlocked.recordUse(of: "ente/1")
        let locked = usage(keychain: LockedKey())
        locked.recordUse(of: "ente/2")
        #expect(locked.ordered(["ente/2", "ente/1"], id: { $0 }) == ["ente/2", "ente/1"])
        #expect(usage().count(for: "ente/1") == 1)
        #expect(usage().count(for: "ente/2") == 0)
    }
}
