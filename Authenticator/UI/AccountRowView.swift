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
    @Environment(\.layoutDirection) private var layoutDirection
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
    @ScaledSize(relativeTo: .body) private var iconSize: CGFloat = 28
    @ScaledSize(relativeTo: .body) private var statusSize: CGFloat = 16
    private let titleStyle = Font.TextStyle.body
    private let subtitleStyle = Font.TextStyle.subheadline
    private let codeStyle = Font.TextStyle.title3
    #else
    @ScaledSize(relativeTo: .body) private var iconSize: CGFloat = 40
    @ScaledSize(relativeTo: .body) private var statusSize: CGFloat = 22
    private let titleStyle = Font.TextStyle.subheadline
    private let subtitleStyle = Font.TextStyle.footnote
    private let codeStyle = Font.TextStyle.body
    /// The narrowest the name gets beside the code. With less room, e.g. with larger text or on a small iPhone, the
    /// code goes on its own line below the name instead.
    @ScaledSize(relativeTo: .subheadline) private var minimumNameWidth: CGFloat = 150
    @ScaledSize(relativeTo: .title) private var barHeight: CGFloat = 3
    private let headlineCodeStyle = Font.TextStyle.title
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

    var body: some View {
        Group {
            #if os(macOS)
            inlineRow
            #else
            // The first that fits: the code beside the name, or below it when the name would get too narrow.
            ViewThatFits(in: .horizontal) {
                inlineRow
                headlineRow
            }
            #endif
        }
        .contentShape(Rectangle())
        // One element for VoiceOver, read as issuer, name and code, then the time left and where it's stored. The
        // code is copied with the row's Copy action.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(account.accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        // Said to Voice Control without the code, e.g. "Tap GitHub".
        .accessibilityInputLabels([account.title] + [account.subTitle.map { "\(account.title) \($0)" }].compactMap { $0 })
        // Stable for UI tests and agents, e.g. "account-row.GitHub:alice@example.com", see docs/accessibility.md.
        .accessibilityIdentifier("account-row.\(account.accountId)")
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

    /// The name and the code side by side.
    private var inlineRow: some View {
        HStack {
            HStack {
                Text(String(account.title.first ?? "?"))
                    .scaledFont(.body)
                    // Grows with the text, but not so much that it crowds the name out.
                    .frame(width: min(iconSize, 64), height: min(iconSize, 64))
                    .background(account.iconColor)
                    .clipShape(.circle)
                    .padding(.trailing, 5)
                    .accessibilityHidden(true)
                VStack(alignment: .leading) {
                    HStack(spacing: 4) {
                        Text(account.title.leftToRightIfAddress)
                            .scaledFont(titleStyle) { $0.weight(.medium) }
                            .lineLimit(1)
                            .minimumScaleFactor(0.9)
                            .truncationMode(.tail)
                        if showsLocation {
                            AccountLocationIcon(account: account)
                                .scaledFont(subtitleStyle)
                                .foregroundStyle(secondaryStyle)
                        }
                    }
                    account.subTitle.map {
                        Text($0.leftToRightIfAddress)
                            .scaledFont(subtitleStyle)
                            .lineLimit(1)
                            .minimumScaleFactor(0.9)
                            .truncationMode(.tail)
                            .foregroundStyle(secondaryStyle)
                    }
                }
                #if !os(macOS)
                // Takes the room the code leaves, but asks for no more than the narrowest it may get, so whether
                // the row fits on one line doesn't depend on how long the name is.
                .frame(minWidth: 0, idealWidth: minimumNameWidth, maxWidth: .infinity, alignment: .leading)
                #endif
            }
            #if os(macOS)
            Spacer()
            #endif
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
    }

    #if !os(macOS)
    /// The issuer and name on one line, then the code in large type with a bar for the time left.
    private var headlineRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                nameLine
                    .scaledFont(titleStyle)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
                if showsLocation {
                    AccountLocationIcon(account: account)
                        .scaledFont(subtitleStyle)
                        .foregroundStyle(secondaryStyle)
                }
            }
            HStack {
                accessory
                if let copyCode {
                    // Borderless so the list gives the tap to the code instead of opening the account.
                    Button(action: copyCode) { headlineCode }
                        .buttonStyle(.borderless)
                        .accessibilityHint(String(localized: "Copies the code", comment: "Accessibility hint for a code in the account list or the Mac menu bar"))
                } else {
                    headlineCode
                }
                Spacer(minLength: 0)
            }
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                BarProgressView(progress: remaining, color: pillColor, animate: animate)
            }
            .frame(height: barHeight)
            // In the tint, like the code in its button above.
            .foregroundStyle(.tint)
            .opacity(isDimmed ? dimmedOpacity : 1)
            .accessibilityHidden(true)
        }
    }

    /// The issuer in bold, then the account name, e.g. "GitHub · alice@example.com".
    private var nameLine: Text {
        guard let subTitle = account.subTitle else {
            return Text(account.title.leftToRightIfAddress).fontWeight(.semibold).foregroundStyle(.primary)
        }
        // Each name in its own direction, and the line in the app's, so the issuer comes first whatever script the
        // names are in: "بنك · alice" in English, and "GitHub · علي" read from the right in Arabic.
        let mark = String.directionMark(rightToLeft: layoutDirection == .rightToLeft)
        let title = Text(mark + account.title.isolated).fontWeight(.semibold).foregroundStyle(.primary)
        return Text("\(title) · \(Text(subTitle.isolated).foregroundStyle(secondaryStyle))", comment: "An account's issuer and name on one line, in the account list with larger text")
    }

    private var headlineCode: some View {
        HStack(spacing: 6) {
            // The bar is empty while there's no code, so the symbol says what's needed to get one.
            if case .countingdown = account.state {} else {
                Image(systemName: account.requiresTouch ? "hand.tap.fill" : "arrow.clockwise.circle.fill")
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }
            codeText
        }
        .scaledFont(headlineCodeStyle) { $0.monospacedDigit().bold() }
        .foregroundStyle(HierarchicalShapeStyle.primary)
        .contentShape(Rectangle())
        .opacity(isDimmed ? dimmedOpacity : 1)
    }

    /// The part of the code's validity that's left, or none while there's no code.
    private var remaining: Double {
        if case .countingdown(let remaining) = account.state { remaining } else { 0 }
    }
    #endif

    // Hierarchical, like the code, so it stays legible on a selected row. The secondary style doesn't get darker with
    // Increase Contrast the way the system's label colors do, so the primary one is used then.
    private var secondaryStyle: HierarchicalShapeStyle {
        colorSchemeContrast == .increased ? .primary : .secondary
    }

    private var accessibilityValue: String {
        showsLocation ? account.accessibilityCodeState + String.accessibilitySeparator + account.locationDescription : account.accessibilityCodeState
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
            codeText
                .scaledFont(codeStyle) { $0.monospacedDigit().bold() }
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

    private var codeText: some View {
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
        ([title] + [subTitle].compactMap { $0 } + [spokenCode]).joined(separator: String.accessibilitySeparator)
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

// The pie and the bar are animated by Core Animation, outside the app. A SwiftUI animation would recompute the shape
// in the app on every frame, which kept the app busy all the time while codes were shown. SwiftUI still fills them,
// so the hierarchical styles follow a selected row; the layer is only the mask.

struct PieProgressView<Style: ShapeStyle>: View {

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let progress: Double
    let color: Style
    let animate: Bool

    init(progress: Double, color: Style, animate: Bool = true) {
        self.progress = progress
        self.color = color
        self.animate = animate
    }

    var body: some View {
        // Steps once a second with Reduce Motion, rather than turning all the time.
        Rectangle()
            .fill(color)
            .mask {
                ProgressLayerView(kind: .pie, progress: progress, animate: animate && !reduceMotion)
                    // Turns clockwise in Arabic and Hebrew too, like a clock, which isn't mirrored.
                    .environment(\.layoutDirection, .leftToRight)
            }
    }
}

/// The time left as a bar that empties from the trailing end, for the account list with larger text.
struct BarProgressView<Style: ShapeStyle>: View {

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    let progress: Double
    let color: Style
    let animate: Bool

    var body: some View {
        Rectangle()
            .fill(color)
            .mask {
                // Drawn from the leading end by the layer itself, so it doesn't depend on whether SwiftUI mirrors the
                // platform view: from the right in Arabic and Hebrew.
                ProgressLayerView(kind: .bar, progress: progress, animate: animate && !reduceMotion,
                                  rightToLeft: layoutDirection == .rightToLeft)
                    .environment(\.layoutDirection, .leftToRight)
            }
    }
}

#if os(iOS)
private typealias PlatformView = UIView
private typealias PlatformViewRepresentable = UIViewRepresentable
#else
private typealias PlatformView = NSView
private typealias PlatformViewRepresentable = NSViewRepresentable
#endif

private struct ProgressLayerView: PlatformViewRepresentable {

    let kind: ProgressLayerHostView.Kind
    let progress: Double
    let animate: Bool
    var rightToLeft = false

    #if os(iOS)
    func makeUIView(context: Context) -> ProgressLayerHostView { ProgressLayerHostView(kind: kind) }
    func updateUIView(_ view: ProgressLayerHostView, context: Context) { view.update(progress: progress, animate: animate, rightToLeft: rightToLeft) }
    #else
    func makeNSView(context: Context) -> ProgressLayerHostView { ProgressLayerHostView(kind: kind) }
    func updateNSView(_ view: ProgressLayerHostView, context: Context) { view.update(progress: progress, animate: animate, rightToLeft: rightToLeft) }
    #endif
}

/// A pie that turns from the top, or a bar that empties from the trailing end, in an opaque color for a mask.
private final class ProgressLayerHostView: PlatformView {

    enum Kind {
        case pie
        case bar
    }

    private let kind: Kind
    // A pie is a circle stroked as wide as its radius and cut off at `strokeEnd`; a bar is a capsule as wide as the
    // part that's left.
    private let shapeLayer = CAShapeLayer()
    private var progress: Double = 0
    /// Whether the bar starts at the right, for Arabic and Hebrew.
    private var rightToLeft = false

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        #if os(macOS)
        wantsLayer = true
        #endif
        shapeLayer.fillColor = kind == .bar ? CGColor(gray: 0, alpha: 1) : nil
        shapeLayer.strokeColor = kind == .pie ? CGColor(gray: 0, alpha: 1) : nil
        shapeLayer.strokeEnd = 0
        hostLayer.addSublayer(shapeLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var hostLayer: CALayer {
        #if os(iOS)
        layer
        #else
        layer!
        #endif
    }

    #if os(iOS)
    override func layoutSubviews() {
        super.layoutSubviews()
        updateShape()
    }
    #else
    override func layout() {
        super.layout()
        updateShape()
    }
    #endif

    private func updateShape() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shapeLayer.frame = bounds
        switch kind {
        case .pie:
            // From the top round to the left. The y axis runs down on iOS, and up on the Mac unless the view is flipped.
            #if os(iOS)
            let direction = -1.0
            #else
            let direction = isFlipped ? -1.0 : 1.0
            #endif
            let top = direction * .pi / 2
            let path = CGMutablePath()
            path.addArc(center: CGPoint(x: bounds.midX, y: bounds.midY), radius: bounds.width / 4,
                        startAngle: top, endAngle: top + direction * 2 * .pi, clockwise: direction < 0)
            shapeLayer.path = path
            shapeLayer.lineWidth = bounds.width / 2
        case .bar:
            shapeLayer.removeAnimation(forKey: "path")
            shapeLayer.path = barPath(progress: progress)
        }
        CATransaction.commit()
    }

    private func barPath(progress: Double) -> CGPath {
        let width = bounds.width * min(max(progress, 0), 1)
        let rect = CGRect(x: rightToLeft ? bounds.maxX - width : bounds.minX, y: bounds.minY, width: width, height: bounds.height)
        let cornerRadius = min(rect.width, rect.height) / 2
        return CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    }

    /// Refills at once, and otherwise runs to the new value in the second until the next one.
    func update(progress: Double, animate: Bool, rightToLeft: Bool = false) {
        if rightToLeft != self.rightToLeft {
            self.rightToLeft = rightToLeft
            updateShape()
        }
        guard progress != self.progress else { return }
        self.progress = progress
        let keyPath = kind == .pie ? "strokeEnd" : "path"
        let fromValue: Any? = kind == .pie ? shapeLayer.presentation()?.strokeEnd : shapeLayer.presentation()?.path
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shapeLayer.removeAnimation(forKey: keyPath)
        switch kind {
        case .pie: shapeLayer.strokeEnd = min(max(progress, 0), 1)
        case .bar: shapeLayer.path = barPath(progress: progress)
        }
        CATransaction.commit()
        guard animate, progress < 1, let fromValue else { return }
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = fromValue
        animation.duration = 1
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        shapeLayer.add(animation, forKey: keyPath)
    }
}
