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

import SwiftUI
import WidgetKit

/// The code of one favorite account on the watch face and in the Smart Stack: the first pinned account, or the first
/// account when none is pinned. The accounts are the ones the iPhone sent, read from the keychain group the watch app
/// shares with this extension.
@main
struct OrielOTPComplications: WidgetBundle {
    var body: some Widget {
        FavoriteCodeWidget()
    }
}

/// The kind the watch app reloads when its accounts change.
nonisolated enum ComplicationKind {
    static let favoriteCode = "io.github.sinf-ken.OrielOTP.FavoriteCode"
}

struct FavoriteEntry: TimelineEntry {
    let date: Date
    /// Nil when there are no accounts, or the keychain can't be read while the watch is locked.
    let account: OTPAccount?
}

struct FavoriteProvider: TimelineProvider {

    func placeholder(in context: Context) -> FavoriteEntry {
        FavoriteEntry(date: .now, account: Self.sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (FavoriteEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : FavoriteEntry(date: .now, account: Self.favorite()))
    }

    /// An entry at each change of the code for the next 10 minutes.
    func getTimeline(in context: Context, completion: @escaping (Timeline<FavoriteEntry>) -> Void) {
        guard let account = Self.favorite() else {
            completion(Timeline(entries: [FavoriteEntry(date: .now, account: nil)], policy: .after(.now.addingTimeInterval(300))))
            return
        }
        let period = Double(account.period)
        let start = (Date.now.timeIntervalSince1970 / period).rounded(.down) * period
        let count = max(1, Int(600 / period))
        let entries = (0..<count).map { index in
            FavoriteEntry(date: index == 0 ? .now : Date(timeIntervalSince1970: start + Double(index) * period), account: account)
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    static func favorite() -> OTPAccount? {
        let accounts = WatchAccountReceiver().accounts.sorted(by: OTPAccount.listOrder)
        return accounts.first(where: \.isPinned) ?? accounts.first
    }

    static let sample = OTPAccount(
        id: "sample", kind: .totp, issuer: "GitHub", accountName: "alice@example.com",
        secret: Data("sample".utf8), algorithm: .sha1, digits: 6, period: 30, isPinned: true)
}

struct FavoriteCodeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: ComplicationKind.favoriteCode, provider: FavoriteProvider()) { entry in
            FavoriteCodeView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName(String(localized: "Favorite Code", comment: "Watch complication name"))
        .description(String(localized: "The code of your first pinned account.", comment: "Watch complication description"))
        .supportedFamilies([.accessoryRectangular, .accessoryInline, .accessoryCircular, .accessoryCorner])
    }
}

struct FavoriteCodeView: View {
    let entry: FavoriteEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let account = entry.account {
            let code = Self.code(of: account, at: entry.date)
            let validity = Self.validity(of: account, at: entry.date)
            switch family {
            case .accessoryInline:
                Text(verbatim: "\(account.title) \(code)")
                    .privacySensitive()
            case .accessoryCircular:
                ProgressView(timerInterval: validity, countsDown: true) {
                    EmptyView()
                } currentValueLabel: {
                    Text(code.replacingOccurrences(of: " ", with: "\n"))
                        .font(.system(.caption2, design: .rounded).monospacedDigit().bold())
                        .multilineTextAlignment(.center)
                        .privacySensitive()
                }
                .progressViewStyle(.circular)
            case .accessoryCorner:
                Text(code)
                    .font(.system(.body, design: .rounded).monospacedDigit().bold())
                    .privacySensitive()
                    .widgetLabel(account.title)
            default:
                VStack(alignment: .leading, spacing: 0) {
                    Text(account.title)
                        .font(.headline)
                        .lineLimit(1)
                    HStack {
                        Text(code)
                            .font(.system(.title3, design: .rounded).monospacedDigit().bold())
                            .privacySensitive()
                        Spacer(minLength: 0)
                        ProgressView(timerInterval: validity, countsDown: true) {
                            EmptyView()
                        } currentValueLabel: {
                            EmptyView()
                        }
                        .progressViewStyle(.circular)
                        .frame(width: 18, height: 18)
                        .accessibilityHidden(true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        } else {
            Text(String(localized: "No accounts", comment: "Watch complication without accounts"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The code in two halves, like the app shows it.
    static func code(of account: OTPAccount, at date: Date) -> String {
        let code = OTPGenerator.code(for: account, at: date)
        guard code.count >= 6, account.kind != .steam else { return code }
        var grouped = code
        grouped.insert(" ", at: grouped.index(grouped.startIndex, offsetBy: code.count / 2))
        return grouped
    }

    static func validity(of account: OTPAccount, at date: Date) -> ClosedRange<Date> {
        let period = Double(account.period)
        let start = (date.timeIntervalSince1970 / period).rounded(.down) * period
        return Date(timeIntervalSince1970: start)...Date(timeIntervalSince1970: start + period)
    }
}
