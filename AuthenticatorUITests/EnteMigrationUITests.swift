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

/// Moves the demo server's accounts to an account created on an empty server, from the settings, confirming each step.
final class EnteMigrationUITests: XCTestCase {

    @MainActor func testMovesAccountsToAnotherServer() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-DemoDate", "1798761612"]
        app.launch()

        let github = app.descendants(matching: .any)["account-row.GitHub:alice@example.com"].firstMatch
        XCTAssertTrue(github.waitForExistence(timeout: 20), "The account list didn't show")
        // Named TopOverflowBarButtonItem from iOS 27.2.
        app.navigationBars.buttons.matching(NSPredicate(format: "identifier IN {'OverflowBarButtonItem', 'TopOverflowBarButtonItem'}")).firstMatch.tap()
        app.buttons["Configuration"].firstMatch.tap()

        let open = app.buttons["ente.migrate"].firstMatch
        for _ in 0..<8 where !open.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(open.waitForExistence(timeout: 20), "The setting didn't show")
        attach("settings", app)
        open.tap()

        let from = app.textFields["ente.migrate.from"]
        XCTAssertTrue(from.waitForExistence(timeout: 20), "The migration sheet didn't show")
        XCTAssertFalse(app.buttons["ente.migrate.continue"].isEnabled, "Continue needs a new server")
        from.tap()
        from.press(forDuration: 1.2)
        if app.menuItems["Select All"].waitForExistence(timeout: 3) {
            app.menuItems["Select All"].tap()
        }
        from.typeText("https://demo.ente.test")
        let to = app.textFields["ente.migrate.to"]
        to.tap()
        to.typeText("https://\(UUID().uuidString.lowercased()).empty.ente.test")
        attach("servers", app)
        app.buttons["ente.migrate.continue"].tap()

        // The old server: an existing account.
        let email = app.textFields["ente.migrate.email"]
        XCTAssertTrue(email.waitForExistence(timeout: 20), "The sign in didn't show")
        email.tap()
        email.typeText("alice@example.com")
        let password = app.secureTextFields["ente.migrate.password"]
        password.tap()
        password.typeText("demo\n")

        // The new server has no account yet, so one is created.
        let create = app.buttons["ente.create-account"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 30), "Creating an account wasn't offered")
        attach("sign-in-new-server", app)
        create.tap()
        let newPassword = app.secureTextFields["ente.sign-up.password"]
        XCTAssertTrue(newPassword.waitForExistence(timeout: 20), "The account creation didn't show")
        let confirmation = app.secureTextFields["ente.sign-up.confirm"]
        typePassword("correct horse", into: newPassword, app)
        XCTAssertEqual((newPassword.value as? String)?.count, 13, "The password lost characters")
        typePassword("correct horse", into: confirmation, app)
        XCTAssertEqual((confirmation.value as? String)?.count, 13, "The confirmation lost characters")
        attach("sign-up", app)
        app.buttons["ente.sign-up.continue"].firstMatch.tap()
        let code = app.textFields["ente.sign-up.code"]
        XCTAssertTrue(code.waitForExistence(timeout: 20), "The email code didn't show")
        code.tap()
        code.typeText("123456")
        app.buttons["ente.sign-up.verify"].firstMatch.tap()
        let created = app.buttons["ente.sign-up.create"].firstMatch
        XCTAssertTrue(created.waitForExistence(timeout: 60), "The recovery key didn't show")
        XCTAssertFalse(created.isEnabled, "The account needs the recovery key to be saved first")
        attach("recovery-key", app)
        app.switches["ente.sign-up.saved"].firstMatch.switches.firstMatch.tap()
        created.tap()
        let done = app.buttons["ente.sign-up.done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 30), "The account wasn't created")
        attach("sign-up-finished", app)
        done.tap()

        // Back on the migration, which kept its sign in to the old server.
        let targetPassword = app.secureTextFields["ente.migrate.password"]
        XCTAssertTrue(targetPassword.waitForExistence(timeout: 20), "The sign in to the new server didn't come back")
        targetPassword.tap()
        targetPassword.typeText("correct horse\n")

        let move = app.buttons["ente.migrate.move"].firstMatch
        XCTAssertTrue(move.waitForExistence(timeout: 30), "The review didn't show")
        attach("review", app)
        move.tap()
        let confirm = app.alerts.buttons["Move accounts"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 20), "The confirmation didn't show")
        attach("confirmation", app)
        confirm.tap()

        let finished = app.buttons["ente.migrate.done"].firstMatch
        XCTAssertTrue(finished.waitForExistence(timeout: 60), "The move didn't finish")
        attach("finished", app)
        finished.tap()
        XCTAssertTrue(open.waitForExistence(timeout: 20), "The sheet didn't close")
        attach("settings-after", app)
    }

    /// Types a new password. On a sign up form iOS first offers a strong password in place of the keyboard, which isn't
    /// part of the app, so it's closed by the position of its close button on an iPhone.
    /// Signs in to a self-hosted server picked on the sign in screen, starting from Ente's own.
    @MainActor func testSignsInToOwnServer() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        // An empty server is Ente's own, so the sign in starts there.
        app.launchArguments = ["-DemoDate", "1798761612", "-EnteAuth.ServerURL", ""]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["account-row.GitHub:alice@example.com"].firstMatch.waitForExistence(timeout: 20),
                      "The account list didn't show")
        app.navigationBars.buttons.matching(NSPredicate(format: "identifier IN {'OverflowBarButtonItem', 'TopOverflowBarButtonItem'}")).firstMatch.tap()
        app.buttons["Sync from Ente Auth"].firstMatch.tap()

        let choice = app.buttons["ente.server-choice"].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 20), "The server choice didn't show")
        XCTAssertFalse(app.textFields["ente.server"].exists, "The address is only asked for with one's own server")
        attach("ente-server", app)
        choice.tap()
        app.buttons["My own server"].firstMatch.tap()

        let server = app.textFields["ente.server"]
        XCTAssertTrue(server.waitForExistence(timeout: 20), "The server address didn't show")
        XCTAssertTrue(app.buttons["ente.create-account"].exists == false, "Creating an account needs an address")
        server.tap()
        server.typeText("https://demo.ente.test\n")
        XCTAssertTrue(app.buttons["ente.create-account"].firstMatch.waitForExistence(timeout: 10), "Creating an account wasn't offered")
        attach("own-server", app)

        let email = app.textFields["ente.email"]
        email.tap()
        email.typeText("alice@example.com\n")
        let password = app.secureTextFields["ente.password"]
        XCTAssertTrue(password.waitForExistence(timeout: 20), "The password field didn't show")
        password.tap()
        password.typeText("demo\n")
        XCTAssertTrue(app.buttons["ente.add"].firstMatch.waitForExistence(timeout: 30), "The accounts on the server didn't show")
        attach("own-server-accounts", app)
    }

    @MainActor private func typePassword(_ text: String, into field: XCUIElement, _ app: XCUIApplication) {
        field.tap()
        if !app.keyboards.firstMatch.waitForExistence(timeout: 5) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.58)).tap()
            field.tap()
        }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 20), "The keyboard didn't show")
        field.typeText(text)
    }

    @MainActor private func attach(_ name: String, _ app: XCUIApplication) {
        Thread.sleep(forTimeInterval: 1)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

#endif
