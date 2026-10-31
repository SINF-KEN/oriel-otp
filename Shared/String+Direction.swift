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

import Foundation

extension String {

    /// The account name to show, kept left to right when it's an email address.
    ///
    /// An address that starts with Arabic or Hebrew, like "علي@example.com", would otherwise be laid out right to left
    /// and show as "example.com@علي". Only for showing: the isolate characters around it would break searching, copying
    /// and comparing.
    ///
    /// This file is shared by the iPhone app and the watch app.
    nonisolated var leftToRightIfAddress: String {
        guard contains("@"), !contains(where: \.isWhitespace) else { return self }
        // Left-to-right isolate and pop directional isolate, so the name around it keeps its own direction.
        return "\u{2066}\(self)\u{2069}"
    }

    /// An account name, email address or device name to put in a sentence, kept in its own direction.
    ///
    /// Without it, an Arabic issuer at the start of "Bank · alice" turns the whole line right to left, and a name that
    /// ends in brackets or digits can take the sentence's punctuation with it. Addresses are kept left to right, like
    /// `leftToRightIfAddress`; other names take the direction of their first letter.
    nonisolated var isolated: String {
        guard contains("@"), !contains(where: \.isWhitespace) else {
            // First strong isolate and pop directional isolate.
            return "\u{2068}\(self)\u{2069}"
        }
        return leftToRightIfAddress
    }

    /// The mark that starts a line made of isolated names, so the line follows the app's direction rather than the
    /// first name's: a right-to-left mark in Arabic and Hebrew, a left-to-right mark otherwise.
    nonisolated static func directionMark(rightToLeft: Bool) -> String {
        rightToLeft ? "\u{200F}" : "\u{200E}"
    }

    /// The digits of other scripts, like the Arabic-Indic ٠١٢٣ that an Arabic keyboard types, as ASCII digits. Codes
    /// and PINs are compared byte for byte, so "١٢٣٤" has to become "1234". Other characters are left as they are.
    nonisolated var asciiDigits: String {
        String(String.UnicodeScalarView(unicodeScalars.map { scalar in
            guard !scalar.isASCII, scalar.properties.numericType == .decimal,
                  let value = scalar.properties.numericValue else { return scalar }
            return Unicode.Scalar(UInt8(48 + Int(value)))
        }))
    }

    /// The separator between the parts of a VoiceOver label, e.g. the issuer, the account name and the code. A comma
    /// in English, "،" in Arabic.
    nonisolated static var accessibilitySeparator: String {
        String(localized: ", ", comment: "Separator between the parts of a VoiceOver label, e.g. the issuer, the account name and the code. Keep the space after it if your language uses one.")
    }
}
