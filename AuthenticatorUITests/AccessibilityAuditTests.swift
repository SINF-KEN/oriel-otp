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

/// Runs Xcode's accessibility audit on the main screens, with the simulated YubiKey and fake Ente server the
/// screenshots use.
final class AccessibilityAuditTests: XCTestCase {

    /// 2027-01-01 00:00:12 UTC, like the screenshots.
    private static let demoDate = "1798761612"

    private var app: XCUIApplication!

    @MainActor override func setUp() async throws {
        continueAfterFailure = true
        app = XCUIApplication()
    }

    /// At the largest accessibility text size no text may be cut off, and all of it has to follow the text size.
    @MainActor func testLargestTextSize() throws {
        app.launchArguments = ["-DemoDate", Self.demoDate,
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        try auditMainScreens(for: [.dynamicType, .textClipped])
    }

    /// Goes through the main screens and audits each: the account list and details, the Ente sign in and account list,
    /// Configuration, About, the tutorial, the app icons and the add account form.
    @MainActor private func auditMainScreens(for types: XCUIAccessibilityAuditType) throws {
        // The first account, which is on screen at every text size.
        let bank = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Bank,'")).firstMatch
        XCTAssertTrue(bank.waitForExistence(timeout: 20), "The simulated YubiKey's accounts didn't show")
        try audit("account list", types)

        bank.tap()
        XCTAssertTrue(app.buttons["Copy"].firstMatch.waitForExistence(timeout: 20), "The account details didn't show")
        try audit("account details", types)
        app.navigationBars.buttons.element(boundBy: 0).tap()

        openMenuItem("Sync from Ente Auth")
        XCTAssertTrue(app.textFields["Email"].waitForExistence(timeout: 20), "The Ente sign in screen didn't show")
        try audit("Ente sign in", types)
        closeSheet()

        openMenuItem("Configuration")
        XCTAssertTrue(app.navigationBars["Configuration"].waitForExistence(timeout: 20), "Configuration didn't show")
        try audit("Configuration", types)
        closeSheet()

        openMenuItem("About")
        XCTAssertTrue(app.navigationBars["About"].waitForExistence(timeout: 20), "About didn't show")
        try audit("About", types)
        app.buttons["How does it work"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Next"].firstMatch.waitForExistence(timeout: 20), "The tutorial didn't show")
        try audit("tutorial", types)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        // Below the fold at the largest text sizes.
        let appIcon = app.buttons["App icon"].firstMatch
        if !appIcon.exists { app.swipeUp() }
        appIcon.tap()
        try audit("app icon", types)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        closeSheet()

        // The scanner asks for the camera first, which the simulator doesn't have, then the form is entered by hand.
        app.navigationBars.buttons["Add account"].firstMatch.tap()
        let cameraAlert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if cameraAlert.waitForExistence(timeout: 5) {
            cameraAlert.buttons.element(boundBy: cameraAlert.buttons.count - 1).tap()
        }
        let enterManually = app.buttons["Enter manually"].firstMatch
        XCTAssertTrue(enterManually.waitForExistence(timeout: 20), "The QR scanner didn't show")
        try audit("QR scanner", types)
        enterManually.tap()
        XCTAssertTrue(app.textFields["Secret"].waitForExistence(timeout: 20), "The add account form didn't show")
        try audit("add account", types)
        closeSheet()

        openMenuItem("Sync from Ente Auth")
        let email = app.textFields["Email"]
        XCTAssertTrue(email.waitForExistence(timeout: 20))
        // Nothing is kept after the test, so the screenshots that follow start signed out. The switch is only there
        // when the simulator has a passcode to protect the session with.
        let staySignedIn = app.switches["Stay signed in"].firstMatch
        for _ in 0..<4 where !staySignedIn.exists {
            app.swipeUp()
        }
        if staySignedIn.exists {
            if staySignedIn.value as? String == "1" {
                staySignedIn.tap()
            }
            XCTAssertEqual(staySignedIn.value as? String, "0", "Stay signed in is still on")
        }
        for _ in 0..<6 where !email.isHittable {
            app.swipeDown()
        }
        email.tap()
        email.typeText("alice@example.com\n")
        let password = app.secureTextFields["Password"]
        XCTAssertTrue(password.waitForExistence(timeout: 20))
        password.tap()
        password.typeText("demo\n")
        let addButton = app.navigationBars.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Add '")).firstMatch
        XCTAssertTrue(addButton.waitForExistence(timeout: 30), "The Ente accounts didn't show")
        try audit("Ente accounts", types)
        closeSheet()
    }

    @MainActor private func openMenuItem(_ title: String) {
        let more = app.navigationBars.buttons["More"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        app.buttons[title].firstMatch.tap()
    }

    @MainActor private func closeSheet() {
        let close = app.navigationBars.buttons.matching(NSPredicate(format: "identifier IN {'Close', 'Cancel'} OR label IN {'Close', 'Cancel'}")).firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        close.tap()
    }

    @MainActor private func audit(_ screen: String, _ types: XCUIAccessibilityAuditType) throws {
        // Lets the sheet or push animation finish, so the audit sees the screen at rest.
        Thread.sleep(forTimeInterval: 1)
        let navigationBarButtons = app.navigationBars.buttons
        try app.performAccessibilityAudit(for: types) { issue in
            // The navigation bar's buttons keep their size, like the system's, and show the Large Content Viewer
            // when held instead.
            if issue.auditType == .dynamicType, let element = issue.element, element.elementType == .button,
               navigationBarButtons[element.label].exists {
                return true
            }
            let element = issue.element.map { "\($0.elementType) '\($0.label)' '\($0.identifier)'" } ?? "no element"
            XCTFail("\(screen): \(issue.compactDescription) – \(element)")
            return true
        }
    }
}

#endif
