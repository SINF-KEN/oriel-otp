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
import SwiftUI
import UIKit
import WidgetKit

@main
struct OrielOTPWidgets: WidgetBundle {
    var body: some Widget {
        PinnedCodesWidget()
        CopyCodeControl()
    }
}

// MARK: - Timeline

struct CodesEntry: TimelineEntry {
    enum Content {
        case accounts([OTPAccount])
        /// Nothing pinned, or Show codes in widgets is off.
        case empty
        /// The file can't be read until the device is unlocked.
        case locked
    }

    let date: Date
    let content: Content
}

struct CodesProvider: TimelineProvider {

    /// One entry per 30 seconds for 10 minutes: every code's period divides into it except odd ones, which show the
    /// code of the moment the entry starts.
    private static let step: TimeInterval = 30
    private static let entries = 20

    func placeholder(in context: Context) -> CodesEntry {
        CodesEntry(date: .now, content: .accounts([Self.sample]))
    }

    func getSnapshot(in context: Context, completion: @escaping (CodesEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : CodesEntry(date: .now, content: Self.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CodesEntry>) -> Void) {
        let content = Self.load()
        guard case .accounts = content else {
            // Read again once the app writes the accounts, or a few minutes later, e.g. after an unlock.
            completion(Timeline(entries: [CodesEntry(date: .now, content: content)], policy: .after(.now.addingTimeInterval(300))))
            return
        }
        let start = (Date.now.timeIntervalSince1970 / Self.step).rounded(.down) * Self.step
        let entries = (0..<Self.entries).map { index in
            CodesEntry(date: index == 0 ? .now : Date(timeIntervalSince1970: start + Double(index) * Self.step), content: content)
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    static func load() -> CodesEntry.Content {
        do {
            guard let accounts = try WidgetAccountsFile().load(), !accounts.isEmpty else { return .empty }
            return .accounts(accounts)
        } catch EncryptedFileError.unavailable {
            return .locked
        } catch {
            return .empty
        }
    }

    static let sample = OTPAccount(
        id: "sample", kind: .totp, issuer: "GitHub", accountName: "alice@example.com",
        secret: Data("sample".utf8), algorithm: .sha1, digits: 6, period: 30, isPinned: true)
}

// MARK: - Widget

struct PinnedCodesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetAccountsFile.widgetKind, provider: CodesProvider()) { entry in
            PinnedCodesView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName(String(localized: "Pinned Codes", comment: "Widget name"))
        .description(String(localized: "The codes of your pinned accounts in Ente Auth and on this device.", comment: "Widget description"))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryInline])
    }
}

struct PinnedCodesView: View {
    let entry: CodesEntry
    @Environment(\.widgetFamily) private var family

    private var limit: Int {
        switch family {
        case .systemSmall, .accessoryRectangular, .accessoryInline: 1
        case .systemMedium: 3
        default: 6
        }
    }

    var body: some View {
        switch entry.content {
        case .accounts(let accounts):
            let shown = Array(accounts.prefix(limit))
            if family == .accessoryInline, let account = shown.first {
                Text(verbatim: "\(account.title) \(Self.code(of: account, at: entry.date))")
                    .privacySensitive()
            } else {
                VStack(alignment: .leading, spacing: family == .systemSmall ? 4 : 8) {
                    ForEach(shown) { account in
                        CodeRow(account: account, date: entry.date, isCompact: family == .systemSmall || family == .accessoryRectangular)
                    }
                    if family != .accessoryRectangular { Spacer(minLength: 0) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        case .empty:
            message(String(localized: "Pin accounts and turn on Show codes in widgets in Oriel OTP.", comment: "Widget without accounts"))
        case .locked:
            message(String(localized: "Unlock to see your codes.", comment: "Widget while the device is locked"))
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The code in two halves, like the app shows it.
    static func code(of account: OTPAccount, at date: Date) -> String {
        let code = OTPGenerator.code(for: account, at: date)
        guard code.count >= 6, account.kind != .steam else { return code }
        var grouped = code
        grouped.insert(" ", at: grouped.index(grouped.startIndex, offsetBy: code.count / 2))
        return grouped
    }
}

private struct CodeRow: View {
    let account: OTPAccount
    let date: Date
    let isCompact: Bool

    var body: some View {
        let period = Double(account.period)
        let start = (date.timeIntervalSince1970 / period).rounded(.down) * period
        let validity = Date(timeIntervalSince1970: start)...Date(timeIntervalSince1970: start + period)
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(account.title)
                    .font(isCompact ? .caption : .subheadline)
                    .lineLimit(1)
                Text(PinnedCodesView.code(of: account, at: date))
                    .font(.system(isCompact ? .title3 : .title2, design: .rounded).monospacedDigit().bold())
                    .privacySensitive()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            ProgressView(timerInterval: validity, countsDown: true) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .progressViewStyle(.circular)
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Control

/// Copy Code in Control Center, on the Lock Screen or on the Action button, for one pinned account.
struct CopyCodeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: WidgetAccountsFile.controlKind, intent: ChooseWidgetAccountIntent.self) { configuration in
            ControlWidgetButton(action: CopyWidgetCodeIntent(accountID: configuration.account?.id)) {
                Label(configuration.account?.title ?? String(localized: "Copy Code", comment: "Control name"), systemImage: "doc.on.doc")
            }
        }
        .displayName(LocalizedStringResource("Copy Code", comment: "Control name"))
        .description(LocalizedStringResource("Copies the code of a pinned account.", comment: "Control description"))
        .promptsForUserConfiguration()
    }
}

/// A pinned account, as the widgets have it.
struct WidgetAccountEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource("Account", comment: "Shortcuts type name"))
    static let defaultQuery = WidgetAccountQuery()

    let id: String
    let title: String
    let accountName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(accountName)")
    }

    init(_ account: OTPAccount) {
        id = account.id
        title = account.title
        accountName = account.accountName
    }
}

struct WidgetAccountQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [WidgetAccountEntity] {
        Self.accounts().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [WidgetAccountEntity] {
        Self.accounts()
    }

    private static func accounts() -> [WidgetAccountEntity] {
        ((try? WidgetAccountsFile().load()) ?? []).map(WidgetAccountEntity.init)
    }
}

struct ChooseWidgetAccountIntent: ControlConfigurationIntent {
    static let title = LocalizedStringResource("Choose Account", comment: "Control configuration")
    static let isDiscoverable = false

    @Parameter(title: LocalizedStringResource("Account", comment: "Shortcuts parameter"))
    var account: WidgetAccountEntity?
}

/// Copies a pinned account's code from the widgets' file, without opening the app.
struct CopyWidgetCodeIntent: AppIntent {
    static let title = LocalizedStringResource("Copy Pinned Code", comment: "Control action")
    static let isDiscoverable = false
    /// Not on a locked device, where the file can't be read anyway.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: LocalizedStringResource("Account", comment: "Shortcuts parameter"))
    var accountID: String?

    init() {}

    init(accountID: String?) {
        self.accountID = accountID
    }

    enum CopyError: LocalizedError {
        case notPinned

        var errorDescription: String? {
            String(localized: "This account isn't pinned in Oriel OTP any more, or Show codes in widgets is off.", comment: "Control error")
        }
    }

    func perform() async throws -> some IntentResult {
        guard let accountID, let account = try WidgetAccountsFile().load()?.first(where: { $0.id == accountID }) else {
            throw CopyError.notPinned
        }
        let code = OTPGenerator.code(for: account, at: .now)
        // Like the app: only on this device, and gone after a minute.
        UIPasteboard.general.setItems(
            [["public.utf8-plain-text": code]],
            options: [.localOnly: true, .expirationDate: Date.now.addingTimeInterval(60)])
        return .result()
    }
}
