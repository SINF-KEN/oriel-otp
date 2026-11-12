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

import AppIntents
import CoreSpotlight
import Foundation
import OSLog

/// Adds the names of the accounts the app calculates codes for to Spotlight, if **Show accounts in Spotlight** is on.
/// Searching for one there opens it in the app, and Copy Code is offered for it. It's off by default: account names
/// say which services someone uses, and Spotlight shows them outside the app lock.
///
/// Only names and tags are added, never codes or secrets. YubiKey accounts aren't added: the app only knows them while
/// the YubiKey is read.
@MainActor @Observable final class AccountSpotlight {

    static let shared = AccountSpotlight()

    static let isEnabledKey = "Spotlight.Enabled"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let indexes: Bool
    @ObservationIgnored private let updateShortcuts: @MainActor () -> Void
    @ObservationIgnored private var updateTask: Task<Void, Never>?
    /// Set when it's turned on or off, until the suggestions are updated.
    @ObservationIgnored private var shortcutsNeedUpdate = false

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Self.isEnabledKey)
            shortcutsNeedUpdate = true
            update()
        }
    }

    /// Without `indexes`, in the tests, nothing is added to Spotlight.
    init(
        defaults: UserDefaults = .standard, indexes: Bool = true,
        updateShortcuts: @escaping @MainActor () -> Void = { OrielOTPShortcuts.updateAppShortcutParameters() }
    ) {
        self.defaults = defaults
        self.indexes = indexes
        self.updateShortcuts = updateShortcuts
        isEnabled = defaults.bool(forKey: Self.isEnabledKey)
    }

    /// Indexes the accounts again a moment after they last changed, or removes them once it is turned off. Siri and
    /// Spotlight's Copy Code suggestions for each account are updated with it while it's on, and once more when it's
    /// turned off, which clears them: `AccountQuery` suggests no accounts then.
    func update() {
        updateTask?.cancel()
        updateTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            if indexes {
                let index = CSSearchableIndex.default()
                do {
                    // Whatever was added before goes, so deleted and renamed accounts don't stay behind.
                    try await index.deleteAppEntities(ofType: AccountEntity.self)
                    if isEnabled {
                        try await index.indexAppEntities(CalculatedAccounts.entities())
                    }
                } catch {
                    Logger.spotlight.error("Spotlight: \(error)")
                }
            }
            if isEnabled || shortcutsNeedUpdate {
                shortcutsNeedUpdate = false
                updateShortcuts()
            }
        }
    }

    /// Waits for the update under way.
    func finishUpdating() async {
        await updateTask?.value
    }
}
