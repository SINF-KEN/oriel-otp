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

// MARK: - The columns: the account list beside the details, or one over the other

extension MainView {

    #if os(macOS)
        /// The narrowest the list and the details get beside each other, in points at 100% text size.
        private static let minimumColumnWidth: CGFloat = 320
        /// The narrowest the window gets, in points at 100% text size, where the codes go below the names.
        static let minimumWindowWidth: CGFloat = 280
        /// Until a view that comes back to the single column can take the focus, after going back to it.
        static let navigationDelay = Duration.milliseconds(400)

        /// Two columns while both fit, otherwise one, as on an iPhone, which also happens as the text gets bigger. A split
        /// view doesn't do this itself on the Mac, and when its columns don't fit, it's centered in the window and cut off
        /// on both sides.
        ///
        /// The layout only changes once a resize ends. Replacing the list during one crashes the app: AppKit ends the
        /// table's live resize as it's removed, which adds rows to a table SwiftUI is already destroying.
        ///
        /// Only whether the columns fit is read here, so the window's content is drawn again when that changes rather than
        /// at every step of a resize. The width the account column can take is read by `SidebarColumnWidth`.
        var mainLayout: some View {
            let minimumWidth = Self.minimumColumnWidth * textScale
            let isSingleColumn = layoutDuringResize ?? !fitsTwoColumns
            return ZStack {
                LiveResizeObserver { isResizing in
                    layoutDuringResize = isResizing ? isSingleColumn : nil
                }
                if isSingleColumn {
                    singleColumnView
                } else {
                    splitView
                }
            }
            .onGeometryChange(for: Bool.self) { geometry in
                geometry.size.width >= 2 * minimumWidth
            } action: { fitsTwoColumns in
                self.fitsTwoColumns = fitsTwoColumns
            }
            .providesContainerSize()
        }

        private var singleColumnView: some View {
            NavigationStack(path: $singleColumnPath) {
                accountColumn()
                    // Below the toolbar, whose search field gets wider than a narrow window and is cut off.
                    .safeAreaInset(edge: .top, spacing: 0) {
                        SingleColumnSearchField(text: $searchText, isFocused: $isSearchFocused)
                    }
                    .environment(\.opensAccount, OpenAccountAction(path: $singleColumnPath))
                    // The arrow keys only move the selection here, so they can get past an account.
                    .onKeyPress(.rightArrow) {
                        guard let selectedAccountID else { return .ignored }
                        singleColumnPath = [selectedAccountID]
                        return .handled
                    }
                    .navigationDestination(for: String.self) { accountID in
                        if let account = model.accounts.first(where: { $0.accountId == accountID }) {
                            accountDetail(account)
                                // Back to the list with Escape, wherever the focus is.
                                .background {
                                    Button(action: { singleColumnPath = [] }) { EmptyView() }
                                        .keyboardShortcut(.cancelAction)
                                        .opacity(0)
                                        .accessibilityHidden(true)
                                }
                        }
                    }
            }
            // AppKit gives the search field the first focus, mostly with larger text, which would keep the arrow keys from
            // the list. With something typed in it, it came from the two columns, so it keeps the focus.
            .onAppear { focusList(overSearch: searchText.isEmpty) }
            // Leaving the search field with Escape goes back to the list.
            .onChange(of: isSearchFocused) { _, isFocused in
                if !isFocused {
                    focusList()
                }
            }
            // The menu bar's commands work on the selection, which the two columns also show when the window gets wider.
            .onChange(of: singleColumnPath) { _, path in
                if let accountID = path.last {
                    selectedAccountID = accountID
                } else {
                    focusList()
                }
            }
        }

        /// Gives the list the focus once it's on screen, unless the search field is about to take it.
        private func focusList(overSearch: Bool = false) {
            Task {
                try? await Task.sleep(for: Self.navigationDelay)
                if overSearch || !isSearchFocused {
                    isListFocused = true
                }
            }
        }

        private var splitView: some View {
            NavigationSplitView {
                accountColumn()
                    .searchable(text: $searchText, placement: .sidebar, prompt: String(localized: "Search"))
                    .searchFocusedBinding($isSearchFocused)
                    .autocorrectionDisabled(true)
                    .modifier(SidebarColumnWidth(minimumColumnWidth: Self.minimumColumnWidth))
            } detail: {
                detailColumn
            }
        }
    #else
        var mainLayout: some View {
            FoldedColumnWidthReader { foldedColumnWidth in
                NavigationSplitView {
                    accountColumn()
                        .searchable(text: $searchText, prompt: String(localized: "Search"))
                        .searchFocusedBinding($isSearchFocused)
                        .autocorrectionDisabled(true)
                        // Wide enough on an iPad for a 6 digit code beside the name at the default text size.
                        .navigationSplitViewColumnWidth(min: 320, ideal: foldedColumnWidth ?? 420, max: foldedColumnWidth)
                        // ⌘F with a hardware keyboard. Search Accounts in the menu bar on the Mac.
                        .background {
                            // Without a label, which the accessibility audit would still see at this opacity.
                            Button(action: focusSearch) { EmptyView() }
                                .keyboardShortcut("f")
                                .opacity(0)
                                .accessibilityHidden(true)
                        }
                        .environment(\.isInFoldedColumn, foldedColumnWidth != nil)
                        .background {
                            FoldedSplitViewAdapter(isOnFold: foldedColumnWidth != nil)
                                .accessibilityHidden(true)
                        }
                } detail: {
                    detailColumn
                }
            }
        }
    #endif

    @ViewBuilder private var detailColumn: some View {
        if let selectedAccount {
            accountDetail(selectedAccount)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: placeholderSize))
                    .foregroundStyle(Color(.tertiaryLabel))
                    .accessibilityHidden(true)
                if model.hasAccounts {
                    Text(
                        String(
                            localized: "Select an account to see its code and details",
                            comment: "Details column before an account is selected")
                    )
                    .scaledFont(.body)
                    .foregroundStyle(Color(.secondaryLabel))
                    .multilineTextAlignment(.center)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // In one half of an iPhone Duo, rather than across the fold.
            .avoidingReservedRegions()
        }
    }

    private func accountDetail(_ account: Account) -> some View {
        AccountDetailView(account: account) {
            selectedAccountID = nil
        }
        .id(account.accountId)
        .scaledBodyFont()
    }

    /// The account list with its toolbar and title.
    private func accountColumn() -> some View {
        accountList
            #if os(macOS)
                .focused($isListFocused)
                // Here rather than for the whole window, so the search field keeps the system's size.
                .scaledBodyFont()
                // Return copies the selected account's code, Delete deletes the selected accounts.
                .onKeyPress(.return) {
                    guard !AppLock.shared.isLocked, let selectedAccount else { return .ignored }
                    toastPresenter.copyCode(of: selectedAccount)
                    return .handled
                }
                .onDeleteCommand {
                    guard !AppLock.shared.isLocked else { return }
                    accountsToDelete = selectedAccounts
                }
            #endif
            .listStyle(.inset)
            .refreshable(enabled: DeviceCapabilities.supportsNFC || model.cloud.isEnabled) {
                otp = nil
                // Synced first, so Face ID for the Ente session isn't asked for while the NFC sheet is up.
                await model.cloud.sync(reportsErrors: true)
                if DeviceCapabilities.supportsNFC {
                    model.updateAccountsOverNFC()
                }
            }
            #if os(macOS)
                // Customizable from the View menu or by Control-clicking the toolbar.
                .toolbar(id: "accounts") { macToolbar }
                .navigationTitle(Text(verbatim: "Oriel OTP"))
            #else
                .toolbar { mainToolbar }
                .navigationTitle(model.hasAccounts ? String(localized: "Accounts", comment: "Navigation title in main view.") : "")
            #endif
    }
}
