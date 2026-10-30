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


struct AccountRowView<Accessory: View>: View {

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var account: Account
    /// Shows whether the account is on the YubiKey or in Ente Auth, for lists that have both.
    private let showsLocation: Bool
    // Shown before the code, e.g. buttons on the Mac while the pointer is over the row.
    private let accessory: Accessory
    /// Called when the code is tapped. Without it the code isn't tappable and a tap opens the row.
    private let copyCode: (() -> Void)?

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    /// An expired or not yet calculated code is dimmed, but not so much that it can't be read.
    @State private var isDimmed: Bool

    @State private var animate: Bool = true

    // Mac lists are denser, with smaller text.
    #if os(macOS)
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 28
    @ScaledMetric(relativeTo: .body) private var statusSize: CGFloat = 16
    private let titleFont = Font.body.weight(.medium)
    private let subtitleFont = Font.subheadline
    private let codeFont = Font.title3.monospacedDigit().bold()
    #else
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 40
    @ScaledMetric(relativeTo: .body) private var statusSize: CGFloat = 22
    private let titleFont = Font.subheadline.weight(.medium)
    private let subtitleFont = Font.footnote
    private let codeFont = Font.body.monospacedDigit().bold()
    #endif

    // Hierarchical so the row stays legible when the list highlights it as selected.
    private let pillColor = HierarchicalShapeStyle.secondary
    
    init(account: Account, showsLocation: Bool = false, copyCode: (() -> Void)? = nil, @ViewBuilder accessory: () -> Accessory) {
        self.account = account
        self.showsLocation = showsLocation
        self.copyCode = copyCode
        self.accessory = accessory()
        self.isDimmed = account.state == .expired || account.otp == nil
    }

    // At accessibility sizes the code goes below the name, so neither has to shrink or truncate to share one line.
    private var isStacked: Bool { dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        let layout = isStacked ? AnyLayout(VStackLayout(alignment: .leading)) : AnyLayout(HStackLayout())
        layout {
            HStack {
                Text(String(account.title.first ?? "?"))
                    // Grows with the text, but not so much that it crowds the name out.
                    .frame(width: min(iconSize, 64), height: min(iconSize, 64))
                    .background(account.iconColor)
                    .clipShape(.circle)
                    .padding(.trailing, 5)
                    .accessibilityHidden(true)
                VStack(alignment: .leading) {
                    HStack(spacing: 4) {
                        Text(account.title)
                            .font(titleFont)
                            .lineLimit(isStacked ? 3 : 1)
                            .minimumScaleFactor(0.9)
                            .truncationMode(.tail)
                        if showsLocation {
                            AccountLocationIcon(account: account)
                                .font(subtitleFont)
                                .foregroundStyle(secondaryStyle)
                        }
                    }
                    account.subTitle.map {
                        Text($0)
                            .font(subtitleFont)
                            .lineLimit(isStacked ? 3 : 1)
                            .minimumScaleFactor(0.9)
                            .truncationMode(.tail)
                            .foregroundStyle(secondaryStyle)
                    }
                }
            }
            if !isStacked {
                Spacer()
            }
            accessory
            if let copyCode {
                // Borderless so the list gives the tap to the code instead of opening the account.
                Button(action: copyCode) { codePill }
                    .buttonStyle(.borderless)
                    .accessibilityHint(String(localized: "Copies the code", comment: "Accessibility hint for a code in the account list or the Mac menu bar"))
            } else {
                codePill
            }
        }
        .contentShape(Rectangle())
        // One element for VoiceOver, read as issuer, name and code, then the time left and where it's stored. The
        // code is copied with the row's Copy action.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(account.accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        // Said to Voice Control without the code, e.g. "Tap GitHub".
        .accessibilityInputLabels([account.title] + [account.subTitle.map { "\(account.title) \($0)" }].compactMap { $0 })
        .onChange(of: account.state) { _, state in
            // Not sure why we have to schedule this in the next runloop
            Task {
                withAnimation {
                    isDimmed = state == .expired || account.otp == nil
                }
            }
        }
        .onAppear() {
            animate = true
        }
        .onDisappear {
            animate = false
        }
    }

    // Hierarchical, like the code, so it stays legible on a selected row. The secondary style doesn't get darker with
    // Increase Contrast the way the system's label colors do, so the primary one is used then.
    private var secondaryStyle: HierarchicalShapeStyle {
        colorSchemeContrast == .increased ? .primary : .secondary
    }

    private var accessibilityValue: String {
        showsLocation ? account.accessibilityCodeState + ", " + account.locationDescription : account.accessibilityCodeState
    }

    private var codePill: some View {
        HStack {
            switch(account.state) {
            case .requiresCalculation, .expired:
                Image(systemName: account.requiresTouch ? "hand.tap.fill" : "arrow.clockwise.circle.fill")
                    .font(.system(size: account.requiresTouch ? statusSize * 18 / 22 : statusSize))
                    // In the code's color, as the pill is dimmed while it shows.
                    .foregroundStyle(HierarchicalShapeStyle.primary)
                    .frame(width: statusSize, height: statusSize)
                    .padding(1)
                    .accessibilityHidden(true)
            case .countingdown(let remaining):
                PieProgressView(progress: remaining,
                                color: pillColor,
                                animate: animate)
                    .frame(width: statusSize, height: statusSize)
                    .padding(1)
                    .accessibilityHidden(true)
            }
            // The code in the full color, the ring and outline lighter. The dimmed code still has a contrast of 4.5:1.
            ZStack {
                if let otp = account.formattedCode {
                    Text(otp)
                        .privacySensitive()
                        // Crossed out as well as dimmed, as a shade is easy to miss.
                        .strikethrough(differentiateWithoutColor && account.state == .expired)
                        .padding(.trailing, 4)
                } else {
                    Text("*** *** ")
                        .padding(.trailing, 4)
                        .padding(.top, 3.5)
                        .padding(.bottom, -3.5)
                }
                Text("888 888") // reserves the code width so the pill doesn't resize
                    .foregroundStyle(.clear)
                    .padding(.trailing, 4)
                    .accessibilityHidden(true)
            }
            .font(codeFont)
            .foregroundStyle(HierarchicalShapeStyle.primary)
        }
        .padding(.all, 4)
        .fixedSize() // keep the code on one line in a narrow sidebar; the title truncates instead
        .foregroundStyle(pillColor)
        .overlay {
            Capsule()
                .stroke(pillColor, lineWidth: 1)
        }
        // Tapping the code copies it; copying is also in the row's context menu and swipe actions.
        .contentShape(Capsule())
        .accessibilityElement()
        .accessibilityLabel(account.spokenCode)
        .opacity(isDimmed ? dimmedOpacity : 1)
    }

    // Not dimmed at all with Increase Contrast; the symbol before the code still says it's expired.
    private var dimmedOpacity: Double {
        colorSchemeContrast == .increased ? 1 : 0.7
    }
}

extension AccountRowView where Accessory == EmptyView {
    init(account: Account, showsLocation: Bool = false, copyCode: (() -> Void)? = nil) {
        self.init(account: account, showsLocation: showsLocation, copyCode: copyCode) { EmptyView() }
    }
}

/// A key for an account on the YubiKey, a cloud for one in Ente Auth, and a clock while a change to an Ente Auth
/// account waits to be uploaded.
struct AccountLocationIcon: View {
    let account: Account

    var body: some View {
        Group {
            if account.isInEnte {
                Image(systemName: account.isPendingSync ? "clock.arrow.circlepath" : "cloud")
            } else {
                Image("securitykey")
            }
        }
        .accessibilityLabel(account.locationDescription)
    }
}

extension Account {
    /// The code for VoiceOver, read digit by digit, e.g. "1 2 3, 4 5 6" rather than "one hundred twenty-three".
    var spokenCode: String {
        if state == .expired {
            return String(localized: "Code expired", comment: "Accessibility label")
        }
        guard let code = formattedCode else {
            return String(localized: "Code not calculated", comment: "Accessibility label")
        }
        return Self.spokenDigits(code)
    }

    /// Splits each group of a code into its characters, so VoiceOver reads them one by one with a pause between groups.
    static func spokenDigits(_ code: String) -> String {
        code.split(separator: " ").map { $0.map(String.init).joined(separator: " ") }.joined(separator: ", ")
    }

    /// The issuer, account name and code, as one sentence for VoiceOver.
    var accessibilityLabel: String {
        ([title] + [subTitle].compactMap { $0 } + [spokenCode]).joined(separator: ", ")
    }

    /// How long the code is valid for, or what's needed to get one.
    var accessibilityCodeState: String {
        if case .countingdown = state, let secondsLeft {
            return String(localized: "\(secondsLeft) seconds left", comment: "VoiceOver, time until the code changes")
        }
        return requiresTouch ? String(localized: "Requires touch", comment: "Mac menu bar help")
            : String(localized: "Calculate to get a code", comment: "VoiceOver, an account whose code hasn't been calculated")
    }

    var locationDescription: String {
        if !isInEnte {
            String(localized: "Stored on YubiKey", comment: "Where an account is stored")
        } else if isPendingSync {
            String(localized: "Stored in Ente Auth, not synced yet", comment: "Where an account is stored, for an Ente Auth account with changes that haven't been uploaded")
        } else {
            String(localized: "Stored in Ente Auth", comment: "Where an account is stored")
        }
    }
}

struct PieProgressView<Style: ShapeStyle>: View {
    
    let progress: Double
    let color: Style
    let animate: Bool

    init(progress: Double, color: Style, animate: Bool = true) {
        self.progress = progress
        self.color = color
        self.animate = animate
    }

    var body: some View {
        var duration = progress >= 1.0 ? 0.0 : 1.0
        duration = animate ? duration : 0.0
        return PieShape(progress: self.progress)
            .foregroundStyle(color)
            .animation(.linear(duration: duration), value: self.progress)
    }
}

nonisolated private struct PieShape: Shape {

    var animatableData: Double {
        get { self.progress }
        set { self.progress = newValue }
    }
    
    var progress: Double = 0.0
    private let start: Double = Double.pi * 1.5
    private var end: Double {
        get {
            return self.start - Double.pi * 2 * self.progress
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center =  CGPoint(x: rect.size.width / 2, y: rect.size.width / 2)
        let radius = rect.size.width / 2
        path.move(to: center)
        path.addArc(center: center, radius: radius, startAngle: Angle(radians: start), endAngle: Angle(radians: end), clockwise: true)
        path.closeSubpath()
        return path
    }
}
