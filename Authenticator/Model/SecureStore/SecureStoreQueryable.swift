/// Copyright (c) 2018 Razeware LLC
/// Copyright (c) 2026 Kenzi Voyer
///
/// Permission is hereby granted, free of charge, to any person obtaining a copy
/// of this software and associated documentation files (the "Software"), to deal
/// in the Software without restriction, including without limitation the rights
/// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
/// copies of the Software, and to permit persons to whom the Software is
/// furnished to do so, subject to the following conditions:
///
/// The above copyright notice and this permission notice shall be included in
/// all copies or substantial portions of the Software.
///
/// Notwithstanding the foregoing, you may not use, copy, modify, merge, publish,
/// distribute, sublicense, create a derivative work, and/or sell copies of the
/// Software in any work that is designed, intended, or marketed for pedagogical or
/// instructional purposes related to programming, coding, application development,
/// or information technology.  Permission for such use, copying, modification,
/// merger, publication, distribution, sublicensing, creation of derivative works,
/// or sale is expressly withheld.
///
/// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
/// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
/// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
/// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
/// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
/// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
/// THE SOFTWARE.
///
/// https://www.raywenderlich.com/9240-keychain-services-api-tutorial-for-passwords-in-swift

import Foundation
import LocalAuthentication

/*!
 APP ID prefix required in case if we want to share storage with our other applications
 */
// The Team ID of the keychain access group. Set it to your own team when sharing the keychain with another app.
nonisolated let APP_ID = ""

nonisolated protocol SecureStoreQueryable: Sendable {
    /// Finds the items, whatever their protection.
    func setUpQuery(useAuthentication: Bool) -> [String: Any]
    /// The protection of an item when it is added. Throws rather than leaving out access control it can't create.
    func protection(useAuthentication: Bool) throws -> [String: Any]
}

/*! Provides simple query to KeyChain specifically for password type of information
 where service is application or web site that password works with.
 Reusing the same name as our Applets on YubiKey have (e.g. OATH)
 Access group is currently not used,
 but potentially can be used if we planning to share this keychain with another application (e.g. YubiKey manager)
 */
nonisolated public struct PasswordQueryable {
    let service: String
    let accessGroup: String?
    /// Who may read a protected item: by default only the currently enrolled Face ID or Touch ID.
    let accessControl: SecAccessControlCreateFlags
    /// What the Touch ID or password prompt says it is for. Nil for the saved YubiKey password.
    let reason: String?
    /// Whether the items get `accessControl` and the access group. Off on the simulator, whose keychain refuses them;
    /// the tests turn it on to check what a device gets.
    let appliesAccessControl: Bool

    static var deviceAppliesAccessControl: Bool {
#if targetEnvironment(simulator)
        false
#else
        true
#endif
    }

    init(service: String, accessGroup: String? = nil, accessControl: SecAccessControlCreateFlags = .biometryCurrentSet, reason: String? = nil,
         appliesAccessControl: Bool = deviceAppliesAccessControl) {
        self.service = service
        self.accessGroup = accessGroup
        self.accessControl = accessControl
        self.reason = reason
        self.appliesAccessControl = appliesAccessControl
    }
}

nonisolated extension PasswordQueryable: SecureStoreQueryable {
    func setUpQuery(useAuthentication: Bool) -> [String: Any] {
        var query: [String: Any] = [:]
        query[String(kSecClass)] = kSecClassGenericPassword
        query[String(kSecAttrService)] = service
#if os(macOS)
        // The Mac has a second, file-based keychain. Use the same data protection keychain as on iOS, which supports
        // the access control flags below and doesn't ask for the login password.
        query[String(kSecUseDataProtectionKeychain)] = true
#endif
        guard appliesAccessControl else { return query }
        if let accessGroup = accessGroup {
            query[String(kSecAttrAccessGroup)] = "\(APP_ID)." + accessGroup
        }

        if useAuthentication {
            let context = LAContext()
            // A protected item is only read after Face ID or Touch ID, as PRIVACY.md says: unlocking the device a
            // few seconds earlier doesn't count.
            context.touchIDAuthenticationAllowableReuseDuration = 0
            context.localizedReason = reason ?? String(localized: "Use the saved YubiKey password.", comment: "Face ID or Touch ID prompt for the saved OATH password of a YubiKey")
            query[String(kSecUseAuthenticationContext)] = context
        }
        return query
    }

    func protection(useAuthentication: Bool) throws -> [String: Any] {
        if useAuthentication && appliesAccessControl {
            var error: Unmanaged<CFError>?
            guard let accessControl = SecAccessControlCreateWithFlags(nil, // use the default allocator
                                                                      kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                                                                      accessControl,
                                                                      &error) else {
                let message = error.map { CFErrorCopyDescription($0.takeRetainedValue()) as String }
                throw SecureStoreError.unhandledError(message: message ?? "No access control")
            }
            return [String(kSecAttrAccessControl): accessControl]
        }
        // Never in backups or on another device, and gone with the app.
        return [String(kSecAttrAccessible): kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
    }
}
