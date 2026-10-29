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
                               "-DemoAppearance", "light", "-DemoWindowSize", "1280x800", "-Mac.ShowInMenuBar", "YES"]
        app.launch()
        app.activate()
    }

    @MainActor override func tearDown() async throws {
        app.terminate()
    }

    @MainActor func testScreenshots() throws {
        let window = app.windows["Oriel OTP"]
        XCTAssertTrue(window.waitForExistence(timeout: 20))
        // A row is one element, labelled with the issuer, the account name and the code.
        let github = window.buttons.matching(NSPredicate(format: "label BEGINSWITH 'GitHub,'")).firstMatch
        XCTAssertTrue(github.waitForExistence(timeout: 20), "The simulated YubiKey's accounts didn't show")
        github.click()
        XCTAssertTrue(window.staticTexts["alice@example.com"].firstMatch.waitForExistence(timeout: 5))
        try save("mac-accounts", window)

        app.typeKey("n", modifierFlags: .command)
        let sheet = window.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        try save("mac-add-account", window)
        app.typeKey(.escape, modifierFlags: [])

        app.typeKey("e", modifierFlags: [.command, .shift])
        // The email field is focused when the sheet opens.
        let email = window.sheets.textFields.firstMatch
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        email.typeText("alice@example.com\r")
        let password = window.sheets.secureTextFields.firstMatch
        XCTAssertTrue(password.waitForExistence(timeout: 10))
        // The ad-hoc signed build has no keychain access group, so it can't keep the session in the keychain.
        let staySignedIn = window.sheets.switches.firstMatch
        XCTAssertTrue(staySignedIn.waitForExistence(timeout: 5))
        if staySignedIn.value as? Int == 1 {
            staySignedIn.click()
        }
        password.click()
        password.typeText("demo\r")
        let alreadyOnYubiKey = window.sheets.buttons.matching(NSPredicate(format: "label ENDSWITH 'Already on YubiKey'")).firstMatch
        XCTAssertTrue(alreadyOnYubiKey.waitForExistence(timeout: 30))
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
        XCTAssertTrue(window.buttons.matching(NSPredicate(format: "label BEGINSWITH 'GitHub,'")).firstMatch.waitForExistence(timeout: 20))

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
