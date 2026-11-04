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
#if os(macOS)

import XCTest

/// Takes the Mac screenshots. Run it with `tools/screenshots-macos.sh`.
///
/// Like the iOS screenshots it uses the debug build's simulated YubiKey and fake Ente server, which the Mac app only
/// uses when launched with `-SimulatedYubiKey YES`, and a frozen clock.
final class MacScreenshotTests: XCTestCase {

    /// 2027-01-01 00:00:12 UTC, 18 seconds before the codes change.
    private static let demoDate = "1798761612"

    private var app: XCUIApplication!

    @MainActor override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-SimulatedYubiKey", "YES", "-DemoDate", Self.demoDate,
                               // A fresh window at its default size, in light mode, every run.
                               "-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO",
                               "-DemoAppearance", "light", "-DemoWindowSize", "1280x800", "-Mac.ShowInMenuBar", "YES",
                               // The fake Ente server, even if this Mac's app has signed in to another one.
                               "-EnteAuth.ServerURL", "https://demo.ente.test"]
        app.launch()
        app.activate()
    }

    @MainActor override func tearDown() async throws {
        app.terminate()
    }

    @MainActor func testScreenshots() throws {
        let window = app.windows["Oriel OTP"]
        XCTAssertTrue(window.waitForExistence(timeout: 20))
        // Elements are found by their accessibility identifiers, see docs/accessibility.md.
        let github = window.descendants(matching: .any)["account-row.GitHub:alice@example.com"].firstMatch
        XCTAssertTrue(github.waitForExistence(timeout: 20), "The simulated YubiKey's accounts didn't show")
        github.click()
        XCTAssertTrue(window.descendants(matching: .any)["account-details.code"].firstMatch.waitForExistence(timeout: 5))
        try save("mac-accounts", window)

        app.typeKey("n", modifierFlags: .command)
        let sheet = window.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        try save("mac-add-account", window)
        app.typeKey(.escape, modifierFlags: [])

        app.typeKey("e", modifierFlags: [.command, .shift])
        // The email field is focused when the sheet opens.
        let email = window.sheets.textFields["ente.email"].firstMatch
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        email.typeText("alice@example.com\r")
        let password = window.sheets.secureTextFields["ente.password"].firstMatch
        XCTAssertTrue(password.waitForExistence(timeout: 10))
        // The ad-hoc signed build has no keychain access group, so it can't keep the session in the keychain.
        let staySignedIn = window.sheets.switches["ente.stay-signed-in"].firstMatch
        XCTAssertTrue(staySignedIn.waitForExistence(timeout: 5))
        if staySignedIn.value as? Int == 1 {
            staySignedIn.click()
        }
        password.click()
        password.typeText("demo\r")
        // The Add button is there once the accounts are listed.
        XCTAssertTrue(window.sheets.buttons["ente.add"].firstMatch.waitForExistence(timeout: 30))
        try save("mac-ente-accounts", window)
        app.typeKey(.escape, modifierFlags: [])

        try openSettings(tab: "General")
        try save("mac-settings", app.windows["General"])
        app.typeKey("w", modifierFlags: .command)

        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        statusItem.click()
        // The menu bar extra's window.
        let menuBarWindow = app.dialogs.firstMatch
        XCTAssertTrue(menuBarWindow.waitForExistence(timeout: 5))
        try save("mac-menu-bar", menuBarWindow)
    }

    /// The other windows, and that the Dock menu's Add Account opens the closed main window.
    @MainActor func testMacWindows() throws {
        let window = app.windows["Oriel OTP"]
        XCTAssertTrue(window.waitForExistence(timeout: 20))
        XCTAssertTrue(window.descendants(matching: .any)["account-row.GitHub:alice@example.com"].firstMatch.waitForExistence(timeout: 20))

        try openSettings(tab: "YubiKey")
        let serialNumber = app.windows["YubiKey"].staticTexts["Serial number"]
        let found = serialNumber.waitForExistence(timeout: 10)
        try attach("check-settings-yubikey", app.windows["YubiKey"])
        XCTAssertTrue(found)
        app.windows["YubiKey"].typeKey("w", modifierFlags: .command)

        app.menuBars.menuBarItems["Help"].click()
        app.menuItems["How It Works"].firstMatch.click()
        let tutorial = app.windows.matching(identifier: "tutorial").firstMatch
        XCTAssertTrue(tutorial.waitForExistence(timeout: 5))
        try attach("check-tutorial", tutorial)
        tutorial.typeKey("w", modifierFlags: .command)

        app.menuBars.menuBarItems["Oriel OTP"].click()
        app.menuItems["About Oriel OTP"].click()
        let about = app.windows.matching(identifier: "about").firstMatch
        XCTAssertTrue(about.waitForExistence(timeout: 5))
        try attach("check-about", about)
        about.typeKey("w", modifierFlags: .command)

        // Closing the main window and asking for Add Account from outside, like the Dock menu, opens it again.
        window.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(window.waitForNonExistence(timeout: 5))
        app.open(URL(string: "orielotp://add-account")!)
        XCTAssertTrue(app.windows["Oriel OTP"].sheets.firstMatch.waitForExistence(timeout: 10))
        try attach("check-reopen", app.windows["Oriel OTP"])
    }

    /// The YubiKey tab's pages leave the Settings window's toolbar alone: its title stays the tab's, and no back button
    /// joins the tabs.
    @MainActor func testYubiKeySettingsPages() throws {
        let window = app.windows["Oriel OTP"]
        XCTAssertTrue(window.waitForExistence(timeout: 20))
        XCTAssertTrue(window.descendants(matching: .any)["account-row.GitHub:alice@example.com"].firstMatch.waitForExistence(timeout: 20))

        try openSettings(tab: "YubiKey")
        let settings = app.windows.matching(identifier: "com_apple_SwiftUI_Settings_window").firstMatch
        XCTAssertTrue(settings.staticTexts["Serial number"].waitForExistence(timeout: 10))
        let toolbarButtons = settings.toolbars.buttons.count
        for page in ["Toggle One-Time Password", "Manage password", "Clear saved passwords", "Reset OATH application"] {
            settings.buttons[page].firstMatch.click()
            Thread.sleep(forTimeInterval: 1)
            try attach("check-settings-\(page)", settings)
            XCTAssertEqual(settings.title, "YubiKey", page)
            XCTAssertEqual(settings.toolbars.buttons.count, toolbarButtons, page)
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(settings.sheets.firstMatch.waitForNonExistence(timeout: 5), page)
            XCTAssertTrue(settings.staticTexts["Serial number"].waitForExistence(timeout: 10), page)
        }
    }

    /// A sidebar dragged wide and a window made narrow afterwards leave the columns inside the window, first as two
    /// and then as one. The split view used to be wider than the window, cut off on both sides.
    @MainActor func testColumnsStayInsideWindow() throws {
        let window = try relaunch(windowSize: "1100x800")
        let row = accountRow(in: window)
        let splitter = window.splitters.firstMatch
        XCTAssertTrue(splitter.waitForExistence(timeout: 5))
        let origin = window.coordinate(withNormalizedOffset: .zero)
        let divider = origin.withOffset(CGVector(dx: splitter.frame.midX - window.frame.minX - 1, dy: 400))
        divider.click(forDuration: 0.3, thenDragTo: divider.withOffset(CGVector(dx: 700, dy: 0)))
        try attach("check-wide-sidebar", window)
        XCTAssertLessThanOrEqual(splitter.frame.maxX, window.frame.maxX - 320, "The details lost their room")

        let corner = origin.withOffset(CGVector(dx: window.frame.width - 1, dy: window.frame.height - 1))
        corner.click(forDuration: 0.3, thenDragTo: corner.withOffset(CGVector(dx: -350, dy: 0)))
        try attach("check-narrow-two-columns", window)
        XCTAssertTrue(splitter.exists, "Still wide enough for two columns")
        XCTAssertGreaterThanOrEqual(row.frame.minX, window.frame.minX)
        XCTAssertLessThanOrEqual(splitter.frame.maxX, window.frame.maxX - 320, "The details lost their room")

        let smallerCorner = origin.withOffset(CGVector(dx: window.frame.width - 1, dy: window.frame.height - 1))
        smallerCorner.click(forDuration: 0.3, thenDragTo: smallerCorner.withOffset(CGVector(dx: -200, dy: 0)))
        try attach("check-narrow-one-column", window)
        XCTAssertFalse(splitter.exists, "One column in a window too narrow for two")
        XCTAssertGreaterThanOrEqual(row.frame.minX, window.frame.minX)
        XCTAssertLessThanOrEqual(row.frame.maxX, window.frame.maxX)
    }

    /// In a narrow window the details open over the list, and Back returns to it.
    @MainActor func testSingleColumnWindow() throws {
        let window = try relaunch(windowSize: "420x700")
        XCTAssertFalse(window.splitters.firstMatch.exists)
        try attach("check-single-column-list", window)
        let code = window.descendants(matching: .any)["account-details.code"].firstMatch
        // Clicking the code copies it without opening the account.
        accountRow(in: window).coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).click()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(code.exists, "Clicking the code opened the account")
        accountRow(in: window).click()
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        try attach("check-single-column-details", window)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(code.waitForNonExistence(timeout: 5))
        XCTAssertTrue(accountRow(in: window).waitForExistence(timeout: 5))
    }

    /// The arrow keys move through the list in one column too, rather than opening each account they pass.
    @MainActor func testSingleColumnKeyboard() throws {
        let window = try relaunch(windowSize: "420x700")
        accountRow(in: window).click()
        let code = window.descendants(matching: .any)["account-details.code"].firstMatch
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(code.waitForNonExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        app.typeKey(.tab, modifierFlags: [])
        Thread.sleep(forTimeInterval: 1)
        try attach("check-single-column-keyboard-before", window)
        app.typeKey(.downArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: 1)
        try attach("check-single-column-keyboard", window)
        XCTAssertFalse(code.exists, "The arrow key opened an account")
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        try attach("check-single-column-keyboard-opened", window)
    }

    /// Bigger text changes to one column at a window size that fits two at 100%.
    @MainActor func testLargestTextUsesOneColumn() throws {
        let window = try relaunch(windowSize: "1000x700", arguments: ["-Mac.TextSize", "2"])
        XCTAssertFalse(window.splitters.firstMatch.exists)
        try attach("check-largest-text", window)
        let row = accountRow(in: window)
        XCTAssertGreaterThanOrEqual(row.frame.minX, window.frame.minX)
        XCTAssertLessThanOrEqual(row.frame.maxX, window.frame.maxX)
    }

    /// The narrowest window has the code below the name, at any text size.
    @MainActor func testNarrowestWindow() throws {
        for (scale, width) in [("1", 280.0), ("2", 560.0)] {
            let window = try relaunch(windowSize: "\(Int(width))x700", arguments: ["-Mac.TextSize", scale])
            XCTAssertEqual(window.frame.width, width)
            try attach("check-narrowest-\(scale)", window)
            let row = accountRow(in: window)
            XCTAssertGreaterThanOrEqual(row.frame.minX, window.frame.minX)
            XCTAssertLessThanOrEqual(row.frame.maxX, window.frame.maxX)
        }
    }

    @MainActor private func relaunch(windowSize: String, arguments: [String] = []) throws -> XCUIElement {
        app.terminate()
        app.launchArguments += ["-DemoWindowSize", windowSize] + arguments
        app.launch()
        app.activate()
        let window = app.windows["Oriel OTP"]
        XCTAssertTrue(window.waitForExistence(timeout: 20))
        XCTAssertTrue(accountRow(in: window).waitForExistence(timeout: 20))
        // The window gets its size just after it opens.
        Thread.sleep(forTimeInterval: 1)
        return window
    }

    @MainActor private func accountRow(in window: XCUIElement) -> XCUIElement {
        window.descendants(matching: .any)["account-row.GitHub:alice@example.com"].firstMatch
    }

    /// Opens the Settings window on a tab. It opens on the tab that was shown last.
    @MainActor private func openSettings(tab: String) throws {
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.matching(identifier: "com_apple_SwiftUI_Settings_window").firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.toolbars.buttons[tab].click()
        XCTAssertTrue(app.windows[tab].waitForExistence(timeout: 5))
    }

    @MainActor private func attach(_ name: String, _ element: XCUIElement) throws {
        Thread.sleep(forTimeInterval: 1)
        let attachment = XCTAttachment(screenshot: element.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Attaches a screenshot of the element to the test result, where `tools/screenshots-macos.sh` picks it up. The
    /// test runner is sandboxed on the Mac, so it can't write the file itself.
    @MainActor private func save(_ name: String, _ element: XCUIElement) throws {
        // Lets animations, like the countdown rings and sheet presentation, finish.
        Thread.sleep(forTimeInterval: 2)
        let attachment = XCTAttachment(screenshot: element.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

#endif
