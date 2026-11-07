/*
 * Copyright (C) 2022 Yubico.
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

// This class is for storing a set of favorite credentials by keyIdentifier. The identifiers name the accounts, so they
// are kept in an encrypted file, which unlike a keychain item goes away with the app. Earlier versions kept them in
// UserDefaults, and they are moved from there the first time they are read.
nonisolated class FavoritesStorage: NSObject {

    private static let key = "Favorites"
    private static let mergedKey = "Favorites.MergedPerDevice"

    private let file: EncryptedFile<Set<String>>
    private let defaults: UserDefaults

    static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(components: "Favorites", "Favorites")
    }

    init(url: URL = defaultURL, keychain: EnteVaultKeychain = EnteVaultKeychainKey(service: "Favorites"), defaults: UserDefaults = .standard) {
        file = EncryptedFile(url: url, keychain: keychain)
        self.defaults = defaults
    }

    /// Adds the favorites kept per YubiKey under "Favorites-<device id>" by the first versions to the others. What was
    /// there is only removed once it's saved, otherwise it's tried again the next time the app starts.
    func migrate() {
        guard !defaults.bool(forKey: Self.mergedKey) else { return }
        let old = defaults.dictionaryRepresentation().filter { $0.key.starts(with: "Favorites-") }
        let merged = old.values.compactMap { $0 as? Data }.compactMap { data in
            try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSSet.self, NSString.self], from: data) as? Set<String>
        }.flatMap { $0 }
        if !merged.isEmpty {
            guard saveFavorites(readFavorites().union(merged)) else { return }
        }
        old.keys.forEach(defaults.removeObject(forKey:))
        defaults.set(true, forKey: Self.mergedKey)
    }

    @discardableResult func saveFavorites(_ favorites: Set<String>) -> Bool {
        guard (try? file.save(favorites)) != nil else { return false }
        defaults.removeObject(forKey: Self.key)
        return true
    }

    /// Empty while the device is locked, unless the favorites weren't moved yet.
    func readFavorites() -> Set<String> {
        if let favorites = try? file.load() { return favorites }
        guard let encodedData = defaults.data(forKey: Self.key),
              let favorites = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSSet.self, NSString.self], from: encodedData) as? Set<String> else {
            return Set<String>()
        }
        saveFavorites(favorites)
        return favorites
    }
}
