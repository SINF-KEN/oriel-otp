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

/*! Represents storage for secure information (e.g. user password/pin)
 Uses KeyChain as permanent storage
 */
nonisolated final class SecureStore: Sendable {
    let secureStoreQueryable: SecureStoreQueryable
    
    public init(secureStoreQueryable: SecureStoreQueryable) {
        self.secureStoreQueryable = secureStoreQueryable
    }
    
    /// Deletes the item and adds it again: updating an item keeps the protection it was added with, so a value saved
    /// with authentication over one saved without it would stay readable without it.
    public func setValue(_ value: Data, useAuthentication: Bool, for userAccount: String) throws {
        let protection = try secureStoreQueryable.protection(useAuthentication: useAuthentication)
        try removeValue(for: userAccount)

        var query = secureStoreQueryable.setUpQuery(useAuthentication: useAuthentication)
        query.merge(protection) { _, new in new }
        query[String(kSecAttrAccount)] = userAccount
        query[String(kSecValueData)] = value
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            throw error(from: status)
        }
    }
    
    public func setValue(_ value: String, useAuthentication: Bool, for userAccount: String) throws {
        guard let encodedPassword = value.data(using: .utf8) else {
            throw SecureStoreError.string2DataConversionError
        }
        try setValue(encodedPassword, useAuthentication: useAuthentication, for: userAccount)
    }
    
    /* getValue is asynchronous to avoid main thread blocking while scanning NFC and
    validating password with device's biometric or passcode protection.
    */
    @concurrent public func getValue(for userAccount: String) async throws -> Data {
        try await getValue(for: userAccount, authentication: nil)
    }

    /// Doesn't ask the user if `authentication` satisfies the item's access control.
    @concurrent func getValue(for userAccount: String, authentication: KeychainAuthentication?) async throws -> Data {
        guard let data = try copyValueData(for: userAccount, useAuthentication: hasValueProtected(for: userAccount), authentication: authentication) else {
            throw SecureStoreError.dataCastError
        }
        return data
    }
    
    @concurrent public func getValue(for userAccount: String) async throws -> String {
        try string(from: copyValueData(for: userAccount, useAuthentication: hasValueProtected(for: userAccount)))
    }
    
    @concurrent public func getValue(for userAccount: String, useAuthentication: Bool) async throws -> String {
        try string(from: copyValueData(for: userAccount, useAuthentication: useAuthentication))
    }
    
    private func string(from data: Data?) throws -> String {
        guard let data, let string = String(data: data, encoding: .utf8) else {
            throw SecureStoreError.data2StringConversionError
        }
        return string
    }
    
    /// Blocks while the user authenticates if the item is protected. Returns nil if the item has no data.
    private func copyValueData(for userAccount: String, useAuthentication: Bool, authentication: KeychainAuthentication? = nil) throws -> Data? {
        var query = secureStoreQueryable.setUpQuery(useAuthentication: useAuthentication)
        if let authentication {
            query[String(kSecUseAuthenticationContext)] = authentication.context
        }
        query[String(kSecMatchLimit)] = kSecMatchLimitOne
        query[String(kSecReturnAttributes)] = kCFBooleanTrue
        query[String(kSecReturnData)] = kCFBooleanTrue
        query[String(kSecAttrAccount)] = userAccount
        
        var queryResult: AnyObject?
        let status = withUnsafeMutablePointer(to: &queryResult) {
            SecItemCopyMatching(query as CFDictionary, $0)
        }
        
        switch status {
        case errSecSuccess:
            let queriedItem = queryResult as? [String: Any]
            let data = queriedItem?[String(kSecValueData)] as? Data
            if let data, !useAuthentication, let accessible = queriedItem?[String(kSecAttrAccessible)] as? String,
               Self.leavesTheDevice.contains(accessible) {
                // Saved by an earlier version, which let it go into backups and onto other devices. If adding it
                // again fails, it is tried again on the next read.
                try? setValue(data, useAuthentication: false, for: userAccount)
            } else if data != nil {
                // Added before the app had a keychain group of its own, where the AutoFill extension can read it.
                // An item that was just added again above is in the app's group already.
                SharedKeychain.moveToAppGroup(query, attributes: queriedItem)
            }
            return data
        case errSecItemNotFound:
            throw SecureStoreError.itemNotFound
        default:
            throw error(from: status)
        }
    }
    
    /// The protection of items that can go into backups and onto other devices.
    private static let leavesTheDevice: Set<String> = [kSecAttrAccessibleWhenUnlocked as String,
                                                       kSecAttrAccessibleAfterFirstUnlock as String]

    public func hasValue(for userAccount: String) -> Bool {
        let status = self.getStatus(for: userAccount)
        switch status {
        case errSecSuccess, errSecInteractionNotAllowed:
            return true
        default:
            return false
        }
    }
    
    public func hasValueProtected(for userAccount: String) -> Bool {
        let status = self.getStatus(for: userAccount)
        return status == errSecInteractionNotAllowed
    }
    
    public func removeAllValues() throws {
        let query = secureStoreQueryable.setUpQuery(useAuthentication: false)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw error(from: status)
        }
    }
        
    private func getStatus(for userAccount: String) -> OSStatus {
        var query = secureStoreQueryable.setUpQuery(useAuthentication: false)
        query[String(kSecAttrAccount)] = userAccount
        let context = LAContext()
        context.interactionNotAllowed = true
        query[String(kSecUseAuthenticationContext)] = context
        return SecItemCopyMatching(query as CFDictionary, nil)
    }
    
    public func removeValue(for userAccount: String) throws {
        var query = secureStoreQueryable.setUpQuery(useAuthentication: false)
        query[String(kSecAttrAccount)] = userAccount
        
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw error(from: status)
        }
    }
    
    private func error(from status: OSStatus) -> SecureStoreError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? String(localized: "Unhandled Error", comment: "Keychain error without a message")
        return SecureStoreError.unhandledError(message: message)
    }
}

/*! Using this hex representation for keys that has format Data, when Store requires only String keys
 */
nonisolated extension Data {
    var hex: String {
        return self.map { b in String(format: "%02X", b) }.joined()
    }
}
