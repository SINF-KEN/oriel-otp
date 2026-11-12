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
            app.launchArguments = [
                "-DemoDate", Self.demoDate, "-CopiedSeconds", "60",
                "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
            ]
            app.launch()
            try auditMainScreens(for: [.dynamicType, .textClipped])
        }

        /// Laid out right to left, as in Arabic and Hebrew, no text may be cut off. The app isn't in either language yet,
        /// so this uses the right-to-left pseudolanguage: English text in a mirrored layout. At the largest text size, like
        /// `testLargestTextSize`: at the default size the audit only warns that text might be cut off at larger sizes.
        @MainActor func testRightToLeft() throws {
            app.launchArguments = [
                "-DemoDate", Self.demoDate, "-CopiedSeconds", "60",
                "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
                "-AppleTextDirection", "YES", "-NSForceRightToLeftWritingDirection", "YES"
            ]
            app.launch()
            try auditMainScreens(for: .textClipped)
        }

        /// In light mode, text and icons have to stand out from their background.
        @MainActor func testLightAppearance() throws {
            app.launchArguments = ["-DemoDate", Self.demoDate, "-CopiedSeconds", "60"]
            app.launch()
            try auditMainScreens(for: .contrast, allowsNearlyPassingContrast: true)
        }

        /// The same in dark mode. Clipped text is checked at the largest text size, where it would show.
        ///
        /// Only the simulator's settings can switch to dark mode and turn on Increase Contrast for the whole app, sheets
        /// included, so `tools/screenshots.sh audits` does, and runs this test and the next one.
        @MainActor func testDarkAppearance() throws {
            try XCTSkipUnless(
                ProcessInfo.processInfo.environment["APPEARANCE"] == "dark",
                "Runs in dark mode, from tools/screenshots.sh audits")
            app.launchArguments = ["-DemoDate", Self.demoDate, "-CopiedSeconds", "60"]
            app.launch()
            try auditMainScreens(for: .contrast, allowsNearlyPassingContrast: true)
        }

        /// With Increase Contrast every text and icon has to have the contrast it needs, 4.5:1 for text and 3:1 for large
        /// text. `tools/screenshots.sh audits` runs it in light and in dark mode.
        @MainActor func testIncreasedContrast() throws {
            try XCTSkipUnless(
                ProcessInfo.processInfo.environment["INCREASE_CONTRAST"] == "enabled",
                "Runs with Increase Contrast on, from tools/screenshots.sh audits")
            app.launchArguments = ["-DemoDate", Self.demoDate, "-CopiedSeconds", "60"]
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

            // The checkmark a row shows after its code is copied, once the toast over the navigation bar has gone.
            let copy = app.buttons["account-row.60/Bank:alice.copy"].firstMatch
            XCTAssertTrue(copy.waitForExistence(timeout: 20), "The code isn't a button of its own")
            copy.tap()
            let toast = app.staticTexts["Copied to clipboard"].firstMatch
            XCTAssertTrue(toast.waitForExistence(timeout: 5), "The toast didn't show")
            XCTAssertTrue(toast.waitForNonExistence(timeout: 15), "The toast didn't go away")
            try audit("copied code", types)

            // On the name, near the top: at the larger sizes the middle of the row is the code, which copies it.
            bank.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
            XCTAssertTrue(app.buttons["account-details.copy"].firstMatch.waitForExistence(timeout: 20), "The account details didn't show")
            try audit("account details", types)
            // On an iPad the details are beside the list, without a back button.
            if UIDevice.current.userInterfaceIdiom == .phone {
                app.navigationBars.buttons.element(boundBy: 0).tap()
            }

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
            // At the largest text sizes a swipe can stop with the field under the navigation bar. It's still hittable then,
            // but the tap lands on the bar, and the field doesn't get the focus.
            let navigationBar = app.navigationBars["Ente Auth"]
            for _ in 0..<6 where !email.isHittable || email.frame.minY < navigationBar.frame.maxY {
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
            // Named TopOverflowBarButtonItem from iOS 27.2.
            let more = app.navigationBars.buttons.matching(
                NSPredicate(format: "identifier IN {'OverflowBarButtonItem', 'TopOverflowBarButtonItem'}")
            ).firstMatch
            XCTAssertTrue(more.waitForExistence(timeout: 10))
            more.tap()
            app.buttons[title].firstMatch.tap()
        }

        @MainActor private func closeSheet() {
            let close = app.navigationBars.buttons.matching(
                NSPredicate(format: "identifier IN {'Close', 'Cancel'} OR label IN {'Close', 'Cancel'}")
            ).firstMatch
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
            // A sheet on an iPad ends above the bottom of the screen. What it cuts off is measured against what's behind it.
            let list = app.sheets.count > 0 || UIDevice.current.userInterfaceIdiom == .pad ? app.collectionViews.firstMatch : nil
            let visibleBottom = list?.exists == true ? list!.frame.maxY : CGFloat.infinity
            let isSidebarInDarkMode =
                UIDevice.current.userInterfaceIdiom == .pad && ["account list", "account details"].contains(screen)
                && ProcessInfo.processInfo.environment["APPEARANCE"] == "dark"
            let screenshot = XCUIScreen.main.screenshot().image
            var failed = false
            try app.performAccessibilityAudit(for: types) { issue in
                if issue.auditType == .contrast {
                    // Disabled controls are dimmed on purpose and don't need the contrast (WCAG 1.4.3).
                    if let element = issue.element,
                        !element.isEnabled || element.frame.intersects(keyboardFrame) || element.frame.maxY > visibleBottom
                    {
                        return true
                    }
                    if allowsNearlyPassingContrast && issue.compactDescription.localizedCaseInsensitiveContains("nearly passed") {
                        return true
                    }
                    // The confirm buttons in the navigation bar (Save, Add) are glass, which the audit misjudges. Measured
                    // in the screenshots: white on #AF001E, 7.3:1, and black on #FFBFCB, 13.6:1. The search field is the
                    // system's, on glass too.
                    if let element = issue.element,
                        element.elementType == .button && navigationBarButtons[element.label].exists || element.elementType == .searchField
                    {
                        return true
                    }
                    // The iPad's sidebar in dark mode is glass, with the details behind it, and the audit fails text level
                    // with what's there, like one Steam code of many or one of two rows in the same color. So what's on
                    // screen decides: the code measures 16.6:1, and white on a light pink selected row 1.6:1. The audit
                    // calls text just short of the contrast it needs nearly passing, 3.1:1 for the secondary labels here.
                    if isSidebarInDarkMode, let element = issue.element, element.elementType == .staticText,
                        Self.contrast(in: element.frame, of: screenshot) >= (allowsNearlyPassingContrast ? 3 : 4.5)
                    {
                        return true
                    }
                }
                // The navigation bar's buttons keep their size, like the system's, and show the Large Content Viewer
                // when held instead.
                if issue.auditType == .dynamicType, let element = issue.element, element.elementType == .button,
                    navigationBarButtons[element.label].exists
                {
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

        /// The WCAG contrast between the lightest and darkest pixels in a frame of a screenshot.
        private static func contrast(in frame: CGRect, of screenshot: UIImage) -> Double {
            let scale = screenshot.scale
            let pixels = CGRect(x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale)
            guard let image = screenshot.cgImage?.cropping(to: pixels), let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
                return 0
            }
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            guard
                let context = CGContext(
                    data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                    space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return 0 }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            func linear(_ byte: UInt8) -> Double {
                let value = Double(byte) / 255
                return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            let luminances = stride(from: 0, to: bytes.count, by: 4).map {
                0.2126 * linear(bytes[$0]) + 0.7152 * linear(bytes[$0 + 1]) + 0.0722 * linear(bytes[$0 + 2])
            }
            guard let lightest = luminances.max(), let darkest = luminances.min() else { return 0 }
            return (lightest + 0.05) / (darkest + 0.05)
        }
    }

#endif
