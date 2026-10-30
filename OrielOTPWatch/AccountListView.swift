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

struct AccountListView: View {

    @Environment(WatchAccountStore.self) private var store

    var body: some View {
        NavigationStack {
            Group {
                if store.accounts.isEmpty {
                    // Scrolls so the whole text can be read at the largest text sizes on the smallest watches.
                    ScrollView {
                        ContentUnavailableView {
                            Label("No Accounts", systemImage: "key.viewfinder")
                        } description: {
                            Text(
                                "Turn on Apple Watch in Oriel OTP on your iPhone, under Sync from Ente Auth.",
                                comment: "Watch empty state. 'Sync from Ente Auth' is the name of the menu item on the iPhone.")
                        }
                    }
                } else {
                    List(store.accounts) { account in
                        AccountRow(account: account)
                    }
                }
            }
            .navigationTitle(Text(verbatim: "Oriel OTP"))
        }
    }
}

private struct AccountRow: View {

    let account: OTPAccount

    @Environment(\.isLuminanceReduced) private var systemLuminanceReduced
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // Ticks on whole seconds, so codes change together with the clock.
        TimelineView(.periodic(from: Date(timeIntervalSince1970: 0), by: 1)) { context in
            let date = DemoMode.date ?? context.date
            let code = OTPGenerator.code(for: account, at: date)
            let secondsLeft = OTPGenerator.secondsLeft(for: account, at: date)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.title)
                    .font(.headline)
                    .lineLimit(2)
                if let subtitle = account.subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                // Wrist down and in Always On only the names are shown.
                if !isLuminanceReduced {
                    let layout =
                        dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                        : AnyLayout(HStackLayout(alignment: .center, spacing: 6))
                    layout {
                        Text(verbatim: OTPGenerator.grouped(code))
                            .font(.system(.title2, design: .monospaced, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        CountdownRing(secondsLeft: secondsLeft, period: account.period)
                    }
                    .privacySensitive()
                }
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(
                isLuminanceReduced
                    ? Text(verbatim: "")
                    : Text(verbatim: code).speechSpellsOutCharacters() + Text(verbatim: ", ")
                        + Text("\(secondsLeft) seconds left", comment: "VoiceOver, time until the code changes"))
        }
    }

    /// Wrist down and in Always On. The simulator can't lower the wrist, so the screenshots fake it.
    private var isLuminanceReduced: Bool {
        systemLuminanceReduced || DemoMode.isLuminanceReduced
    }

    private var accessibilityLabel: Text {
        if let subtitle = account.subtitle {
            return Text(verbatim: "\(account.title), \(subtitle)")
        }
        return Text(verbatim: account.title)
    }
}

/// A small ring that empties as the code gets older.
private struct CountdownRing: View {

    let secondsLeft: Int
    let period: Int

    @ScaledMetric(relativeTo: .title2) private var size: CGFloat = 18
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    /// Orange in the last seconds, and dashed too when color shouldn't be the only sign.
    private var isEnding: Bool { secondsLeft <= 5 }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: 3)
            Circle()
                .trim(from: 0, to: CGFloat(secondsLeft) / CGFloat(max(1, period)))
                .stroke(
                    isEnding ? Color.orange : Color.accentColor,
                    style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: isEnding && differentiateWithoutColor ? [2, 4] : [])
                )
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
