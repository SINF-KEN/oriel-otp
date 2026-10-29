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

import Foundation
import Testing
@testable import OrielOTP

struct AccessKeyCacheTests {

    let key = Data([0x01, 0x02, 0x03])
    let start = Date(timeIntervalSince1970: 1_000_000)

    @Test func returnsKeyWithinTimeToLive() {
        var cache = AccessKeyCache()
        cache.setAccessKey(key, forKey: "device", now: start)
        #expect(cache.accessKey(forKey: "device", now: start.addingTimeInterval(cache.timeToLive - 1)) == key)
    }

    @Test func unknownDeviceHasNoKey() {
        var cache = AccessKeyCache()
        cache.setAccessKey(key, forKey: "device", now: start)
        #expect(cache.accessKey(forKey: "other", now: start) == nil)
    }

    @Test func expiredKeyIsRemoved() {
        var cache = AccessKeyCache()
        cache.setAccessKey(key, forKey: "device", now: start)
        let expired = start.addingTimeInterval(cache.timeToLive)
        #expect(cache.accessKey(forKey: "device", now: expired) == nil)
        // Still gone when asked again at a time it would have been valid.
        #expect(cache.accessKey(forKey: "device", now: start) == nil)
    }

    @Test func readingRestartsTimeToLive() {
        var cache = AccessKeyCache()
        cache.setAccessKey(key, forKey: "device", now: start)
        let read = start.addingTimeInterval(cache.timeToLive - 1)
        #expect(cache.accessKey(forKey: "device", now: read) == key)
        #expect(cache.accessKey(forKey: "device", now: read.addingTimeInterval(cache.timeToLive - 1)) == key)
    }

    @Test func settingAgainReplacesKey() {
        var cache = AccessKeyCache()
        cache.setAccessKey(key, forKey: "device", now: start)
        cache.setAccessKey(Data([0xff]), forKey: "device", now: start)
        #expect(cache.accessKey(forKey: "device", now: start) == Data([0xff]))
    }
}

// The tests read and write the shared UserDefaults keys the app uses, so they must not run in parallel.
@Suite(.serialized)
final class FavoritesStorageTests {

    private let storage = FavoritesStorage()
    private let savedFavorites = UserDefaults.standard.data(forKey: "Favorites")

    deinit {
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.starts(with: "Favorites-") {
            UserDefaults.standard.removeObject(forKey: key)
        }
        UserDefaults.standard.set(savedFavorites, forKey: "Favorites")
    }

    private func archive(_ favorites: Set<String>) throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: favorites, requiringSecureCoding: true)
    }

    @Test func savedFavoritesAreRead() {
        storage.saveFavorites(["Example:alice", "60/bob"])
        #expect(storage.readFavorites() == ["Example:alice", "60/bob"])
    }

    @Test func missingFavoritesReadAsEmpty() {
        UserDefaults.standard.removeObject(forKey: "Favorites")
        #expect(storage.readFavorites().isEmpty)
    }

    @Test func unreadableFavoritesReadAsEmpty() {
        UserDefaults.standard.set(Data("not an archive".utf8), forKey: "Favorites")
        #expect(storage.readFavorites().isEmpty)
    }

    // Favorites used to be saved per YubiKey under "Favorites-<device id>".
    @Test func migrationMergesPerDeviceFavorites() throws {
        UserDefaults.standard.removeObject(forKey: "Favorites")
        UserDefaults.standard.set(try archive(["Example:alice"]), forKey: "Favorites-1234")
        UserDefaults.standard.set(try archive(["Example:alice", "GitHub:bob"]), forKey: "Favorites-5678")

        storage.migrate()

        #expect(storage.readFavorites() == ["Example:alice", "GitHub:bob"])
        #expect(UserDefaults.standard.object(forKey: "Favorites-1234") == nil)
        #expect(UserDefaults.standard.object(forKey: "Favorites-5678") == nil)
    }

    @Test func migrationWithoutPerDeviceFavoritesKeepsFavorites() {
        storage.saveFavorites(["Example:alice"])
        storage.migrate()
        #expect(storage.readFavorites() == ["Example:alice"])
    }
}

struct PasswordPreferencesTests {

    private let preferences = PasswordPreferences()
    // The UserDefaults key is spelled out so renaming it, which would lose saved preferences, fails the tests.
    // A device id of its own, so the tests don't touch the preferences of a real YubiKey.
    private let deviceId = "test-\(UUID().uuidString)"

    private func cleanUp(_ ids: String...) {
        for id in ids {
            UserDefaults.standard.removeObject(forKey: "PasswordSaveType" + id)
        }
    }

    @Test(arguments: [
        (PasswordSaveType.none, false, false),
        (.never, false, false),
        (.save, true, false),
        (.lock, false, true),
    ])
    func saveTypeSelectsHowPasswordIsUsed(saveType: PasswordSaveType, usesSavedPassword: Bool, usesScreenLock: Bool) {
        defer { cleanUp(deviceId) }
        preferences.setPasswordPreference(saveType: saveType, keyIdentifier: deviceId)
        #expect(preferences.useSavedPassword(keyIdentifier: deviceId) == usesSavedPassword)
        #expect(preferences.useScreenLock(keyIdentifier: deviceId) == usesScreenLock)
    }

    @Test func unknownDeviceUsesNoSavedPassword() {
        #expect(!preferences.useSavedPassword(keyIdentifier: deviceId))
        #expect(!preferences.useScreenLock(keyIdentifier: deviceId))
    }

    @Test func resetForgetsPreference() {
        defer { cleanUp(deviceId) }
        preferences.setPasswordPreference(saveType: .save, keyIdentifier: deviceId)
        preferences.resetPasswordPreference(keyIdentifier: deviceId)
        #expect(!preferences.useSavedPassword(keyIdentifier: deviceId))
    }

    @Test func migrateMovesPreferenceToNewId() {
        let newDeviceId = deviceId + "-new"
        defer { cleanUp(deviceId, newDeviceId) }
        preferences.setPasswordPreference(saveType: .lock, keyIdentifier: deviceId)
        preferences.migrate(fromKeyIdentifier: deviceId, toKeyIdentifier: newDeviceId)
        #expect(preferences.useScreenLock(keyIdentifier: newDeviceId))
        #expect(UserDefaults.standard.object(forKey: "PasswordSaveType" + deviceId) == nil)
    }
}
