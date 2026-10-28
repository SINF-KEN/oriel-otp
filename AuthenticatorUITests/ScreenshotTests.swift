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

import XCTest

/// Takes the screenshots shown in the README. Run it with `tools/screenshots.sh`.
///
/// It uses the debug build's simulated YubiKey and fake Ente server, so every account is made up and nothing
/// leaves the simulator. The clock is frozen, so the codes and timers are the same on every run.
final class ScreenshotTests: XCTestCase {

    /// 2027-01-01 00:00:12 UTC, 18 seconds before the codes change.
    private static let demoDate = "1798761612"

    private var app: XCUIApplication!

    @MainActor override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-DemoDate", Self.demoDate]
        app.launch()
    }

    @MainActor func testScreenshots() throws {
        let github = app.staticTexts["GitHub"].firstMatch
        XCTAssertTrue(github.waitForExistence(timeout: 20), "The simulated YubiKey's accounts didn't show")
        try save("accounts")

        github.tap()
        XCTAssertTrue(app.staticTexts["alice@example.com"].firstMatch.waitForExistence(timeout: 5))
        try save("account-details")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.navigationBars.buttons["More"].firstMatch.tap()
        app.buttons["Sync from Ente Auth"].firstMatch.tap()
        // The sign in screen isn't kept: its focused field's blinking cursor would make every run different.
        let email = app.textFields["Email"]
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        email.tap()
        // Return submits, like the Continue and Sign in buttons, whose names the keyboard's return key shares.
        email.typeText("alice@example.com\n")
        let password = app.secureTextFields["Password"]
        XCTAssertTrue(password.waitForExistence(timeout: 10))
        password.tap()
        password.typeText("demo\n")
        XCTAssertTrue(app.staticTexts["Already on YubiKey"].firstMatch.waitForExistence(timeout: 30))
        try save("ente-accounts")
    }

    /// Writes a screenshot to `SCREENSHOT_DIR`, or attaches it to the test result when that isn't set.
    @MainActor private func save(_ name: String) throws {
        // Lets animations, like the countdown rings and sheet presentation, finish.
        Thread.sleep(forTimeInterval: 2)
        let screenshot = XCUIScreen.main.screenshot()
        if let directory = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"], !directory.isEmpty {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
            try screenshot.pngRepresentation.write(to: url)
        } else {
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
