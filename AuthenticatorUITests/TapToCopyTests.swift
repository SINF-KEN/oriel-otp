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

#if os(iOS)

import UIKit
import XCTest

/// Tapping the code in the account list copies it, and tapping the rest of the row opens the account, with the
/// simulated YubiKey the screenshots use.
final class TapToCopyTests: XCTestCase {

    /// 2027-01-01 00:00:12 UTC, like the screenshots.
    private static let demoDate = "1798761612"

    private var app: XCUIApplication!

    @MainActor override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    /// The code is beside the name.
    @MainActor func testTapCodeCopies() throws {
        app.launchArguments = ["-DemoDate", Self.demoDate]
        app.launch()
        try assertTapCopies(codeAt: CGVector(dx: 0.8, dy: 0.5))
    }

    /// Above the code, which looks about 30 points tall, but has to take at least 44 to tap.
    @MainActor func testTapJustAboveCodeCopies() throws {
        app.launchArguments = ["-DemoDate", Self.demoDate]
        app.launch()
        try assertTapCopies(codeAt: CGVector(dx: 0.8, dy: 0.5), offsetBy: CGVector(dx: 0, dy: -24))
    }

    /// The code is below the name, in large type.
    @MainActor func testTapCodeCopiesWithLargerText() throws {
        app.launchArguments = ["-DemoDate", Self.demoDate,
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"]
        app.launch()
        try assertTapCopies(codeAt: CGVector(dx: 0.3, dy: 0.6))
    }

    @MainActor func testTapNameOpensAccount() throws {
        app.launchArguments = ["-DemoDate", Self.demoDate]
        app.launch()
        let row = try bankRow()
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["account-details.copy"].firstMatch.waitForExistence(timeout: 10), "The account didn't open")
        XCTAssertFalse(app.staticTexts["Copied to clipboard"].exists, "Opening the account copied its code")
    }

    @MainActor private func assertTapCopies(codeAt offset: CGVector, offsetBy points: CGVector = .zero) throws {
        let row = try bankRow()
        let changeCount = UIPasteboard.general.changeCount
        row.coordinate(withNormalizedOffset: offset).withOffset(points).tap()
        XCTAssertTrue(app.staticTexts["Copied to clipboard"].firstMatch.waitForExistence(timeout: 10), "No Copied to clipboard toast")
        XCTAssertNotEqual(UIPasteboard.general.changeCount, changeCount, "Nothing was copied")
        XCTAssertTrue(UIPasteboard.general.hasStrings, "Nothing was copied")
        XCTAssertFalse(app.buttons["account-details.copy"].firstMatch.waitForExistence(timeout: 2), "Tapping the code opened the account")
    }

    /// The first account, which is on screen at every text size.
    @MainActor private func bankRow() throws -> XCUIElement {
        let bank = app.descendants(matching: .any)["account-row.60/Bank:alice"].firstMatch
        XCTAssertTrue(bank.waitForExistence(timeout: 20), "The simulated YubiKey's accounts didn't show")
        return bank
    }
}

#endif
