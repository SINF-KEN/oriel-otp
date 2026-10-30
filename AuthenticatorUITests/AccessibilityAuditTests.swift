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
    private var allowsNearlyPassingContrast = false

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

    /// In light mode, text and icons have to stand out from their background.
    @MainActor func testLightAppearance() throws {
        app.launchArguments = ["-DemoDate", Self.demoDate]
        app.launch()
        try auditMainScreens(for: .contrast, allowsNearlyPassingContrast: true)
    }

    /// The same in dark mode. Clipped text is checked at the largest text size, where it would show.
    ///
    /// Only the simulator's settings can switch to dark mode and turn on Increase Contrast for the whole app, sheets
    /// included, so `tools/screenshots.sh` does after the screenshots, and runs this test and the next one again.
    @MainActor func testDarkAppearance() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APPEARANCE"] == "dark",
                          "Runs in dark mode, from tools/screenshots.sh")
        app.launchArguments = ["-DemoDate", Self.demoDate]
        app.launch()
        try auditMainScreens(for: .contrast, allowsNearlyPassingContrast: true)
    }

    /// With Increase Contrast every text and icon has to have the contrast it needs, 4.5:1 for text and 3:1 for large
    /// text. `tools/screenshots.sh` runs it in light and in dark mode.
    @MainActor func testIncreasedContrast() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["INCREASE_CONTRAST"] == "enabled",
                          "Runs with Increase Contrast on, from tools/screenshots.sh")
        app.launchArguments = ["-DemoDate", Self.demoDate]
        app.launch()
        try auditMainScreens(for: .contrast)
    }

    /// Goes through the main screens and audits each: the account list and details, the Ente sign in and account list,
    /// Configuration, About, the tutorial, the app icons and the add account form.
    /// With `allowsNearlyPassingContrast`, text that's just short of the contrast it needs, like the system's secondary
    /// labels in dark mode, isn't reported. With Increase Contrast it has to pass.
    @MainActor private func auditMainScreens(for types: XCUIAccessibilityAuditType, allowsNearlyPassingContrast: Bool = false) throws {
        self.allowsNearlyPassingContrast = allowsNearlyPassingContrast
        // The first account, which is on screen at every text size.
        let bank = app.descendants(matching: .any)["account-row.60/Bank:alice"].firstMatch
        XCTAssertTrue(bank.waitForExistence(timeout: 20), "The simulated YubiKey's accounts didn't show")
        try audit("account list", types)

        bank.tap()
        XCTAssertTrue(app.buttons["account-details.copy"].firstMatch.waitForExistence(timeout: 20), "The account details didn't show")
        try audit("account details", types)
        app.navigationBars.buttons.element(boundBy: 0).tap()

        openMenuItem("Sync from Ente Auth")
        XCTAssertTrue(app.textFields["ente.email"].waitForExistence(timeout: 20), "The Ente sign in screen didn't show")
        dismissKeyboard()
        try audit("Ente sign in", types)
        closeSheet()

        openMenuItem("Configuration")
        XCTAssertTrue(app.navigationBars["Configuration"].waitForExistence(timeout: 20), "Configuration didn't show")
        try audit("Configuration", types)
        closeSheet()

        openMenuItem("About")
        XCTAssertTrue(app.navigationBars["About"].waitForExistence(timeout: 20), "About didn't show")
        try audit("About", types)
        app.buttons["about.tutorial"].firstMatch.tap()
        XCTAssertTrue(app.buttons["tutorial.next"].firstMatch.waitForExistence(timeout: 20), "The tutorial didn't show")
        try audit("tutorial", types)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        // Below the fold at the largest text sizes.
        let appIcon = app.buttons["about.app-icon"].firstMatch
        if !appIcon.exists { app.swipeUp() }
        appIcon.tap()
        try audit("app icon", types)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        closeSheet()

        // The scanner asks for the camera first, which the simulator doesn't have, then the form is entered by hand.
        app.navigationBars.buttons["accounts.add-account"].firstMatch.tap()
        let cameraAlert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if cameraAlert.waitForExistence(timeout: 5) {
            cameraAlert.buttons.element(boundBy: cameraAlert.buttons.count - 1).tap()
        }
        let enterManually = app.buttons["add-account.enter-manually"].firstMatch
        XCTAssertTrue(enterManually.waitForExistence(timeout: 20), "The QR scanner didn't show")
        try audit("QR scanner", types)
        enterManually.tap()
        XCTAssertTrue(app.textFields["add-account.secret"].waitForExistence(timeout: 20), "The add account form didn't show")
        try audit("add account", types)
        closeSheet()

        openMenuItem("Sync from Ente Auth")
        let email = app.textFields["ente.email"]
        XCTAssertTrue(email.waitForExistence(timeout: 20))
        // Nothing is kept after the test, so the screenshots that follow start signed out. The switch is only there
        // when the simulator has a passcode to protect the session with.
        let staySignedIn = app.switches["ente.stay-signed-in"].firstMatch
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
        let password = app.secureTextFields["ente.password"]
        XCTAssertTrue(password.waitForExistence(timeout: 20))
        password.tap()
        password.typeText("demo\n")
        let addButton = app.buttons["ente.add"].firstMatch
        XCTAssertTrue(addButton.waitForExistence(timeout: 30), "The Ente accounts didn't show")
        try audit("Ente accounts", types)
        closeSheet()
    }

    /// The email field is focused when the sign in opens. The keyboard, and the tip a new simulator shows over it,
    /// would be audited as the background of what's behind them.
    @MainActor private func dismissKeyboard() {
        let tip = app.buttons["Continue"].firstMatch
        if tip.waitForExistence(timeout: 2) {
            tip.tap()
        }
        // Scrolling the form puts the keyboard away, if it's long enough to scroll. Not down, which would close the
        // sheet. Otherwise what's under the keyboard is left out of the audit.
        if app.keyboards.firstMatch.exists {
            app.collectionViews.firstMatch.swipeUp()
        }
    }

    /// Taps an item of the account list's More menu. The menu is the system's, and its items don't keep their
    /// identifiers, so they're found by their title.
    @MainActor private func openMenuItem(_ title: String) {
        let more = app.navigationBars.buttons["OverflowBarButtonItem"].firstMatch
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
        let allowsNearlyPassingContrast = allowsNearlyPassingContrast
        // What the keyboard covers can't be seen, so its contrast is measured against the keyboard. Its frame leaves
        // out the bar above the keys (Passwords, predictions), so that's added.
        let keyboard = app.keyboards.firstMatch
        let keyboardFrame = keyboard.exists ? keyboard.frame.inset(by: UIEdgeInsets(top: -60, left: 0, bottom: 0, right: 0)) : .null
        var failed = false
        try app.performAccessibilityAudit(for: types) { issue in
            if issue.auditType == .contrast {
                // Disabled controls are dimmed on purpose and don't need the contrast (WCAG 1.4.3).
                if let element = issue.element, !element.isEnabled || element.frame.intersects(keyboardFrame) {
                    return true
                }
                if allowsNearlyPassingContrast && issue.compactDescription.localizedCaseInsensitiveContains("nearly passed") {
                    return true
                }
                // The confirm buttons in the navigation bar (Save, Add) are glass, which the audit misjudges. Measured
                // in the screenshots: white on #AF001E, 7.3:1, and black on #FFBFCB, 13.6:1. The search field is the
                // system's, on glass too.
                if let element = issue.element,
                   element.elementType == .button && navigationBarButtons[element.label].exists || element.elementType == .searchField {
                    return true
                }
            }
            // The navigation bar's buttons keep their size, like the system's, and show the Large Content Viewer
            // when held instead.
            if issue.auditType == .dynamicType, let element = issue.element, element.elementType == .button,
               navigationBarButtons[element.label].exists {
                return true
            }
            let element = issue.element.map { "\($0.elementType) '\($0.label)' '\($0.identifier)'" } ?? "no element"
            XCTFail("\(screen): \(issue.compactDescription) – \(element): \(issue.detailedDescription)")
            failed = true
            return true
        }
        // Shows what the audit saw, in the test result.
        if failed {
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "audit-\(screen)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}

#endif
