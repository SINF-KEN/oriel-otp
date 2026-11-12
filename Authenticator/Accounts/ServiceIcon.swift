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

/// The icon of a brand, from Simple Icons, shown for an account in place of its first letter. The icons are the
/// image sets in `ServiceIcons` of the asset catalog, made by `tools/service-icons.swift`, which also writes
/// `catalog`.
nonisolated struct ServiceIcon: Sendable, Equatable {
    let slug: String
    /// The brand's color, as 0xRRGGBB.
    let color: UInt32
    /// The brand's name and the other names it goes by.
    let names: [String]

    var imageName: String { "ServiceIcons/" + slug }

    /// The icon for an account: the one chosen for it in Ente Auth, or else the one of the brand its issuer names, e.g.
    /// "GitHub", "github.com" or "Google Workspace". Without an issuer, the account name is used, but not as a domain:
    /// alice@gmail.com may well not be a Google account.
    static func icon(issuer: String?, accountName: String, iconID: String? = nil) -> ServiceIcon? {
        if let iconID, let icon = index[normalized(iconID)] {
            return icon
        }
        if let issuer = issuer?.trimmingCharacters(in: .whitespaces), !issuer.isEmpty {
            return match(issuer, asDomain: true)
        }
        return match(accountName.trimmingCharacters(in: .whitespaces), asDomain: false)
    }

    private static func match(_ name: String, asDomain: Bool) -> ServiceIcon? {
        if let icon = index[normalized(name)] {
            return icon
        }
        // "accounts.google.com" or "github.com": the name before the top level domain, skipping "co" in "co.uk".
        if asDomain, name.contains("."), !name.contains(" ") {
            let host = name.split(separator: "@").last.map(String.init) ?? name
            let labels = host.split(separator: ".").dropLast()
            if let label = labels.last(where: { $0.count > 2 }), let icon = index[normalized(String(label))] {
                return icon
            }
        }
        // "Google Workspace" or "GitHub (work)": the first word, if it's long enough to be a name.
        let words = name.split { $0.isWhitespace || "()[]-–—,:/|".contains($0) }
        if words.count > 1, let first = words.first, first.count >= 3 {
            return index[normalized(String(first))]
        }
        return nil
    }

    /// By name and slug, without case, accents, spaces or punctuation.
    private static let index: [String: ServiceIcon] = {
        var index = [String: ServiceIcon]()
        for icon in catalog {
            for name in [icon.slug] + icon.names {
                let key = normalized(name)
                // The first icon keeps a name two brands share.
                if !key.isEmpty, index[key] == nil {
                    index[key] = icon
                }
            }
        }
        return index
    }()

    /// "Crédit Agricole" and "credit-agricole" both give "creditagricole".
    static func normalized(_ name: String) -> String {
        String(
            name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
                .lowercased()
                .unicodeScalars
                .filter { CharacterSet.alphanumerics.contains($0) })
    }

    // MARK: - Colors

    var background: Color {
        Color(red: component(16), green: component(8), blue: component(0))
    }

    /// White or black, whichever stands out more from the brand's color.
    var foreground: Color {
        usesDarkForeground ? .black : .white
    }

    var usesDarkForeground: Bool {
        let luminance = 0.2126 * linear(component(16)) + 0.7152 * linear(component(8)) + 0.0722 * linear(component(0))
        // The contrast with black, (L + 0.05) / 0.05, is higher than with white, 1.05 / (L + 0.05).
        return (luminance + 0.05) * (luminance + 0.05) > 1.05 * 0.05
    }

    private func component(_ shift: UInt32) -> Double {
        Double((color >> shift) & 0xff) / 255
    }

    private func linear(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
}

/// An account's icon: the brand's, or its first letter on a color of its own.
struct AccountIconView: View {
    let account: Account
    /// The width and height of the circle.
    let size: CGFloat
    /// The style of the letter, when there's no icon.
    let letterStyle: Font.TextStyle

    var body: some View {
        Group {
            if let icon = account.serviceIcon {
                Image(icon.imageName)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(icon.foreground)
                    .padding(size * 0.24)
                    .frame(width: size, height: size)
                    .background(icon.background)
            } else {
                Text(String(account.title.first ?? "?"))
                    .scaledFont(letterStyle)
                    // Not the row's, which changes on a selected row, on an icon that doesn't.
                    .foregroundStyle(Color(.label))
                    .frame(width: size, height: size)
                    .background(account.iconColor)
            }
        }
        .clipShape(.circle)
        // Beside the account's name, which says what it is.
        .accessibilityHidden(true)
    }
}
