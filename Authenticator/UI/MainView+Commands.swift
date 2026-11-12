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

// MARK: - The menu bar and keyboard commands

extension MainView {

    #if os(macOS)
    var selectedAccounts: [Account] {
        model.accounts.filter { selectedAccountIDs.contains($0.accountId) }
    }

    var menuState: MainWindowMenuState {
        let selection = selectedAccounts
        return MainWindowMenuState(canAddAccount: true,
                                   canRefresh: model.canRefresh,
                                   canSearch: true,
                                   selectionCount: selection.count,
                                   isSelectionPinned: !selection.isEmpty && selection.allSatisfy(\.isPinned),
                                   canRename: selection.count == 1 && selection[0].canRename,
                                   canCopyToYubiKey: model.isKeyPluggedIn && selection.count == 1 && model.canCopyToYubiKey(selection[0], moving: false),
                                   canMoveToYubiKey: model.isKeyPluggedIn && selection.count == 1 && model.canCopyToYubiKey(selection[0], moving: true))
    }

    /// Does what was chosen in the menu bar.
    func perform(_ command: MainWindowCommands.Command) {
        let selection = selectedAccounts
        switch command {
        case .addAccount:
            addAccount()
        case .syncFromEnte:
            showEnteSync = true
        case .refresh:
            model.refresh()
        case .search:
            // The search field is on the list, so an account open over it closes first. Set again each time, as the
            // field doesn't report back when it wasn't there to take the focus.
            let delay = singleColumnPath.isEmpty ? Duration.zero : Self.navigationDelay
            singleColumnPath = []
            focusSearch(after: delay)
        case .copyCode:
            if let selectedAccount { toastPresenter.copyCode(of: selectedAccount) }
        case .togglePin:
            let pin = !selection.allSatisfy(\.isPinned)
            selection.forEach { $0.isPinned = pin }
        case .rename:
            accountToRename = selectedAccount
        case .copyToYubiKey, .moveToYubiKey:
            if let selectedAccount {
                CopyToYubiKeyButtons.copy(selectedAccount, moving: command == .moveToYubiKey, model: model, toastPresenter: toastPresenter)
            }
        case .delete:
            accountsToDelete = selection
        }
    }
    #endif

    func focusSearch() {
        focusSearch(after: .zero)
    }

    func focusSearch(after delay: Duration) {
        isSearchFocused = false
        Task {
            try? await Task.sleep(for: delay)
            isSearchFocused = true
        }
    }
}
