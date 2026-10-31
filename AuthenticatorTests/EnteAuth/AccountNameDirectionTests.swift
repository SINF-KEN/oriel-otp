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

import Testing

@testable import OrielOTP

struct AccountNameDirectionTests {

    @Test func addressIsKeptLeftToRight() {
        #expect("علي@example.com".leftToRightIfAddress == "\u{2066}علي@example.com\u{2069}")
        #expect("alice@example.com".leftToRightIfAddress == "\u{2066}alice@example.com\u{2069}")
    }

    @Test func otherNamesAreUnchanged() {
        #expect("أحمد".leftToRightIfAddress == "أحمد")
        #expect("Server root".leftToRightIfAddress == "Server root")
        #expect("@ home".leftToRightIfAddress == "@ home")
    }

    @Test func namesInASentenceAreIsolated() {
        // First strong isolate for a name, left-to-right isolate for an address.
        #expect("بنك".isolated == "\u{2068}بنك\u{2069}")
        #expect("GitHub (work)".isolated == "\u{2068}GitHub (work)\u{2069}")
        #expect("علي@example.com".isolated == "\u{2066}علي@example.com\u{2069}")
    }

    @Test func directionMarkFollowsTheLayout() {
        #expect(String.directionMark(rightToLeft: true) == "\u{200F}")
        #expect(String.directionMark(rightToLeft: false) == "\u{200E}")
    }

    @Test func otherDigitsBecomeASCII() {
        #expect("١٢٣٤٥٦".asciiDigits == "123456") // Arabic-Indic
        #expect("۰۹".asciiDigits == "09") // Persian
        #expect("१२".asciiDigits == "12") // Devanagari
        #expect("12 ab-٣".asciiDigits == "12 ab-3")
        // Not decimal digits, so left alone.
        #expect("½²".asciiDigits == "½²")
    }
}
