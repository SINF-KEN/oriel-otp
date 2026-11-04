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

import XCTest

/// Someone with no YubiKey and no Ente account can add an account and get its codes.
final class NoYubiKeyTests: XCTestCase {

    private var app: XCUIApplication!

    @MainActor override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    @MainActor func testAddAnAccountWithoutAYubiKey() throws {
        unplugSimulatedYubiKey()
        let add = app.buttons["accounts.empty-add-account"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 20), "The empty list doesn't offer to add an account")
        XCTAssertTrue(add.isEnabled)
        attachScreenshot("empty-list")
        add.tap()

        let manually = app.buttons["add-account.enter-manually"].firstMatch
        if manually.waitForExistence(timeout: 5) {
            manually.tap()
        }
        let issuer = app.textFields["add-account.issuer"].firstMatch
        XCTAssertTrue(issuer.waitForExistence(timeout: 20), "The add account form didn't show")
        issuer.tap()
        issuer.typeText("Example")
        let name = app.textFields["add-account.account-name"].firstMatch
        name.tap()
        name.typeText("alice")
        let secret = app.textFields["add-account.secret"].firstMatch
        secret.tap()
        secret.typeText("JBSWY3DPEHPK3PXP")
        attachScreenshot("add-account")
        app.buttons["add-account.save"].firstMatch.tap()

        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'account-row.device/'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "The account isn't in the list")
        attachScreenshot("account-list")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()

        XCTAssertTrue(app.buttons["account-details.copy"].firstMatch.waitForExistence(timeout: 20), "The account didn't open")
        XCTAssertTrue(app.buttons["account-details.copy"].firstMatch.isEnabled, "The account has no code")
        XCTAssertTrue(app.staticTexts["Stored on this device"].firstMatch.exists)
        attachScreenshot("account-details")

        // Leaves the simulator as it was, and the delete alert is what says there's no other copy.
        app.navigationBars.buttons.matching(NSPredicate(format: "identifier IN {'OverflowBarButtonItem', 'TopOverflowBarButtonItem'}")).firstMatch.tap()
        // The More menu's items are the system's, which don't keep their identifiers.
        app.buttons["Delete"].firstMatch.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 20))
        attachScreenshot("delete-alert")
        alert.buttons["Delete"].tap()
        XCTAssertTrue(app.buttons["accounts.empty-add-account"].firstMatch.waitForExistence(timeout: 20), "The account wasn't deleted")
    }

    @MainActor private func unplugSimulatedYubiKey() {
        let more = app.navigationBars.buttons.matching(NSPredicate(format: "identifier IN {'OverflowBarButtonItem', 'TopOverflowBarButtonItem'}")).firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 20))
        more.tap()
        app.buttons["Simulated YubiKey"].firstMatch.tap()
        app.descendants(matching: .any)["Plugged in"].firstMatch.tap()
    }

    @MainActor private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

#endif
