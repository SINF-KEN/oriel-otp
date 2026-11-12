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
import CryptoKit
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

struct FavoritesStorageTests {

    private let url = URL.temporaryDirectory.appending(components: "FavoritesStorageTests-\(UUID().uuidString)", "Favorites")
    private let keychain = InMemoryVaultKey()
    private let defaults = UserDefaults(suiteName: "FavoritesStorageTests-\(UUID().uuidString)")!
    private var storage: FavoritesStorage { FavoritesStorage(url: url, keychain: keychain, defaults: defaults) }

    private func archive(_ favorites: Set<String>) throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: favorites, requiringSecureCoding: true)
    }

    @Test func savedFavoritesAreRead() {
        storage.saveFavorites(["Example:alice", "60/bob"])
        #expect(storage.readFavorites() == ["Example:alice", "60/bob"])
    }

    @Test func theAccountNamesAreNotInTheFile() throws {
        storage.saveFavorites(["Example:alice"])
        let file = try Data(contentsOf: url)
        #expect(file.range(of: Data("alice".utf8)) == nil)
    }

    // Favorites used to be kept in UserDefaults, in the clear.
    @Test func favoritesAreMovedOutOfUserDefaults() throws {
        defaults.set(try archive(["Example:alice"]), forKey: "Favorites")
        #expect(storage.readFavorites() == ["Example:alice"])
        #expect(defaults.object(forKey: "Favorites") == nil)
        #expect(storage.readFavorites() == ["Example:alice"])
    }

    @Test func favoritesStayInUserDefaultsUntilTheyAreSaved() throws {
        let storage = FavoritesStorage(url: url, keychain: UnavailableVaultKey(), defaults: defaults)
        defaults.set(try archive(["Example:alice"]), forKey: "Favorites")
        #expect(storage.readFavorites() == ["Example:alice"])
        #expect(defaults.object(forKey: "Favorites") != nil)
    }

    @Test func missingFavoritesReadAsEmpty() {
        #expect(storage.readFavorites().isEmpty)
    }

    @Test func unreadableFavoritesReadAsEmpty() {
        defaults.set(Data("not an archive".utf8), forKey: "Favorites")
        #expect(storage.readFavorites().isEmpty)
    }

    // Favorites used to be saved per YubiKey under "Favorites-<device id>".
    @Test func migrationMergesPerDeviceFavorites() throws {
        defaults.set(try archive(["Example:alice"]), forKey: "Favorites-1234")
        defaults.set(try archive(["Example:alice", "GitHub:bob"]), forKey: "Favorites-5678")

        storage.migrate()

        #expect(storage.readFavorites() == ["Example:alice", "GitHub:bob"])
        #expect(defaults.object(forKey: "Favorites-1234") == nil)
        #expect(defaults.object(forKey: "Favorites-5678") == nil)
    }

    @Test func migrationAddsToTheFavoritesAlreadySaved() throws {
        storage.saveFavorites(["Example:alice"])
        defaults.set(try archive(["GitHub:bob"]), forKey: "Favorites-1234")
        storage.migrate()
        #expect(storage.readFavorites() == ["Example:alice", "GitHub:bob"])
    }

    @Test func migrationThatCanNotSaveKeepsTheOldFavoritesAndTriesAgain() throws {
        defaults.set(try archive(["GitHub:bob"]), forKey: "Favorites-1234")
        FavoritesStorage(url: url, keychain: UnavailableVaultKey(), defaults: defaults).migrate()
        #expect(defaults.object(forKey: "Favorites-1234") != nil)

        storage.migrate()
        #expect(storage.readFavorites() == ["GitHub:bob"])
        #expect(defaults.object(forKey: "Favorites-1234") == nil)
    }

    @Test func migrationRunsOnce() throws {
        storage.migrate()
        defaults.set(try archive(["GitHub:bob"]), forKey: "Favorites-1234")
        storage.migrate()
        #expect(storage.readFavorites().isEmpty)
    }

    @Test func migrationWithoutPerDeviceFavoritesKeepsFavorites() {
        storage.saveFavorites(["Example:alice"])
        storage.migrate()
        #expect(storage.readFavorites() == ["Example:alice"])
    }
}

/// A keychain that can't be read, like while the device is locked.
private struct UnavailableVaultKey: EncryptedFileKey {
    func existingKey() throws -> SymmetricKey? { throw EncryptedFileError.unavailable }
    func createKey() throws -> SymmetricKey { throw EncryptedFileError.unavailable }
    func removeKey() {}
}

struct PasswordPreferencesTests {

    // Preferences of their own, removed after each test, so nothing is left in the app's.
    private let suiteName = "PasswordPreferencesTests-\(UUID().uuidString)"
    private let defaults: UserDefaults
    private let preferences: PasswordPreferences
    // The UserDefaults key is spelled out so renaming it, which would lose saved preferences, fails the tests.
    private let deviceId = "test-device"

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
        preferences = PasswordPreferences(defaults: defaults)
    }

    private func cleanUp(_ ids: String...) {
        defaults.removePersistentDomain(forName: suiteName)
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
        defer { cleanUp() }
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
        #expect(defaults.object(forKey: "PasswordSaveType" + deviceId) == nil)
    }
}
