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


struct AccountRowView: View {

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var account: Account

    @State private var pillOpacity: Double

    @State private var animate: Bool = true

    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 40
    @ScaledMetric(relativeTo: .body) private var statusSize: CGFloat = 22

    // Hierarchical so the row stays legible when the list highlights it as selected.
    private let pillColor = HierarchicalShapeStyle.secondary
    
    init(account: Account) {
        self.account = account
        if account.state == .expired || account.otp == nil {
            self.pillOpacity = 0.5
        } else {
            self.pillOpacity = 1.0
        }
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
                    Text(account.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(isStacked ? 3 : 1)
                        .minimumScaleFactor(0.9)
                        .truncationMode(.tail)
                    account.subTitle.map {
                        Text($0)
                            .font(.footnote)
                            .lineLimit(isStacked ? 3 : 1)
                            .minimumScaleFactor(0.9)
                            .truncationMode(.tail)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if !isStacked {
                Spacer()
            }
            codePill
        }
        .contentShape(Rectangle())
        .onChange(of: account.state) { _, state in
            // Not sure why we have to schedule this in the next runloop
            Task {
                withAnimation {
                    if state == .expired || account.otp == nil {
                        pillOpacity = 0.5
                    } else {
                        pillOpacity = 1.0
                    }
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

    private var codePill: some View {
        HStack {
            switch(account.state) {
            case .requiresCalculation, .expired:
                Image(systemName: account.requiresTouch ? "hand.tap.fill" : "arrow.clockwise.circle.fill")
                    .font(.system(size: account.requiresTouch ? statusSize * 18 / 22 : statusSize))
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
            ZStack {
                if let otp = account.formattedCode {
                    Text(otp)
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
            }
            .font(.body.monospacedDigit().bold())
        }
        .padding(.all, 4)
        .fixedSize() // keep the code on one line in a narrow sidebar; the title truncates instead
        .foregroundStyle(pillColor)
        .overlay {
            Capsule()
                .stroke(pillColor, lineWidth: 1)
        }
        // Not a button: copying is one of the row's actions, in its context menu and swipe actions.
        .accessibilityElement()
        .accessibilityLabel(account.state == .expired ? String(localized: "Code expired", comment: "Accessibility label") : account.formattedCode ?? String(localized: "Code not calculated", comment: "Accessibility label"))
        .opacity(pillOpacity)
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
