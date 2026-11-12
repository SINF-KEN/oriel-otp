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

import Foundation
import LocalAuthentication
import Security
import Testing

@testable import OrielOTP

/// How the items behind Face ID or Touch ID are protected on a device. The simulator's keychain refuses access
/// control, so the app leaves it out there and these tests check what a device gets instead of saving anything.
struct KeychainProtectionTests {

    private static func flags(of protection: [String: Any]) throws -> SecAccessControl {
        let value = try #require(protection[String(kSecAttrAccessControl)])
        return value as! SecAccessControl
    }

    private static func accessControl(_ flags: SecAccessControlCreateFlags) -> SecAccessControl {
        SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, flags, nil)!
    }

    @Test func theEnteSessionNeedsTheCurrentFaceIDOrTouchID() throws {
        let queryable = EnteSessionStore.queryable(service: "test", appliesAccessControl: true)
        #if os(macOS)
            #expect(queryable.accessControl == .userPresence)
        #else
            #expect(queryable.accessControl == .biometryCurrentSet)
        #endif
        let protection = try queryable.protection(useAuthentication: true)
        // Only on this device, only with a passcode, and never anything that would let it be read without one.
        #expect(protection[String(kSecAttrAccessible)] == nil)
        #expect(CFEqual(try Self.flags(of: protection), Self.accessControl(queryable.accessControl)))
        #expect(!CFEqual(try Self.flags(of: protection), Self.accessControl(.devicePasscode)))
    }

    @Test func savedYubiKeyPasswordsNeedTheCurrentFaceIDOrTouchID() throws {
        let queryable = PasswordQueryable(service: KeychainService.oathPasswords, appliesAccessControl: true)
        #expect(queryable.accessControl == .biometryCurrentSet)
        #expect(CFEqual(try Self.flags(of: queryable.protection(useAuthentication: true)), Self.accessControl(.biometryCurrentSet)))
    }

    /// A Face ID or Touch ID check from unlocking the device a moment ago doesn't count.
    @Test func readingAsksForFaceIDOrTouchIDEachTime() throws {
        let queryable = EnteSessionStore.queryable(service: "test", appliesAccessControl: true)
        let query = queryable.setUpQuery(useAuthentication: true)
        let context = try #require(query[String(kSecUseAuthenticationContext)] as? LAContext)
        #expect(context.touchIDAuthenticationAllowableReuseDuration == 0)
        #expect(context.localizedReason == queryable.reason)
        #expect(queryable.setUpQuery(useAuthentication: false)[String(kSecUseAuthenticationContext)] == nil)
    }

    /// Items without Face ID or Touch ID stay on this device too.
    @Test func itemsWithoutAuthenticationStayOnThisDevice() throws {
        let protection = try PasswordQueryable(service: "test", appliesAccessControl: true).protection(useAuthentication: false)
        #expect(protection[String(kSecAttrAccessControl)] == nil)
        #expect(protection[String(kSecAttrAccessible)] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    }

    @Test func theSimulatorLeavesOutWhatItsKeychainRefuses() throws {
        let queryable = PasswordQueryable(service: "test", accessGroup: "group", appliesAccessControl: false)
        #expect(queryable.setUpQuery(useAuthentication: true)[String(kSecUseAuthenticationContext)] == nil)
        #expect(queryable.setUpQuery(useAuthentication: true)[String(kSecAttrAccessGroup)] == nil)
        #expect(try queryable.protection(useAuthentication: true)[String(kSecAttrAccessControl)] == nil)
        #expect(
            PasswordQueryable(service: "test", accessGroup: "group", appliesAccessControl: true)
                .setUpQuery(useAuthentication: false)[String(kSecAttrAccessGroup)] as? String == "\(APP_ID).group")
    }
}
