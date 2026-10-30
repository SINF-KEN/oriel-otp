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

/// What VoiceOver reads for a code.
struct AccessibilityLabelTests {

    @Test func codesAreReadDigitByDigit() {
        #expect(Account.spokenDigits("123 456") == "1 2 3, 4 5 6")
        #expect(Account.spokenDigits("1234 5678") == "1 2 3 4, 5 6 7 8")
    }

    @Test func steamCodesAreReadCharacterByCharacter() {
        #expect(Account.spokenDigits("5KQ2R") == "5 K Q 2 R")
    }
}
