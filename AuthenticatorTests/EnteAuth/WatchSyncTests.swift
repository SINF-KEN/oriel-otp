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
import Testing

#if os(iOS)
    import WatchConnectivity
#endif

@testable import OrielOTP

/// A keychain item in memory, which can be locked like the keychain of a locked device.
final class MemoryKeychainItem: WatchKeychainItem, @unchecked Sendable {

    private let lock = NSLock()
    private var _data: Data?
    private var _isLocked = false

    init(_ data: Data? = nil) {
        _data = data
    }

    var data: Data? {
        lock.withLock { _data }
    }

    var isLocked: Bool {
        get { lock.withLock { _isLocked } }
        set { lock.withLock { _isLocked = newValue } }
    }

    func read() -> KeychainRead {
        lock.withLock {
            if _isLocked { return .unavailable }
            return _data.map(KeychainRead.found) ?? .notFound
        }
    }

    @discardableResult func write(_ data: Data?) -> Bool {
        lock.withLock {
            if _isLocked { return false }
            _data = data
            return true
        }
    }
}

private func account(_ id: String, issuer: String = "GitHub", name: String = "alice") -> OTPAccount {
    OTPAccount(
        id: id, kind: .totp, issuer: issuer, accountName: name, secret: Data("12345678901234567890".utf8),
        algorithm: .sha1, digits: 6, period: 30, isPinned: false)
}

private func makeDefaults() -> UserDefaults {
    UserDefaults(suiteName: "WatchSyncTests-\(UUID().uuidString)")!
}

private func legacyContext(_ accounts: [OTPAccount]) throws -> [String: Any] {
    ["version": 1, "accounts": try JSONEncoder().encode(accounts)]
}

struct WatchAccountsMessageTests {

    private let accounts = [account("1"), account("2", issuer: "Zoom", name: "bob")]

    @Test func sealedAccountsOpenWithTheKey() throws {
        let key = WatchSyncKey.generate()
        let context = try WatchAccountsMessage.context(for: accounts, key: key)
        #expect(WatchAccountsMessage.content(of: context, key: key) == .accounts(accounts))
        #expect(context["keyID"] as? String == key.id)
        #expect(WatchAccountsMessage.isCurrent(context))
    }

    /// The context, which the system keeps on disk, has neither the secrets nor the names.
    @Test func theContextHasNothingInTheClear() throws {
        let context = try WatchAccountsMessage.context(for: accounts, key: WatchSyncKey.generate())
        let data = try PropertyListSerialization.data(fromPropertyList: context, format: .binary, options: 0)
        for needle in ["12345678901234567890", "GitHub", "alice", "Zoom", "secret"] {
            #expect(data.range(of: Data(needle.utf8)) == nil)
        }
        #expect(context["accounts"] == nil)
    }

    @Test func eachContextIsSealedWithANewNonce() throws {
        let key = WatchSyncKey.generate()
        let first = try WatchAccountsMessage.context(for: accounts, key: key)["sealed"] as? Data
        let second = try WatchAccountsMessage.context(for: accounts, key: key)["sealed"] as? Data
        #expect(first != second)
    }

    @Test func noKeyOrAnotherKeyAsksForTheKey() throws {
        let key = WatchSyncKey.generate()
        let context = try WatchAccountsMessage.context(for: accounts, key: key)
        #expect(WatchAccountsMessage.content(of: context, key: nil) == .needsKey(id: key.id))
        #expect(WatchAccountsMessage.content(of: context, key: WatchSyncKey.generate()) == .needsKey(id: key.id))
    }

    @Test func aChangedContextIsUnreadable() throws {
        let key = WatchSyncKey.generate()
        var context = try WatchAccountsMessage.context(for: accounts, key: key)
        var sealed = try #require(context["sealed"] as? Data)
        sealed[sealed.count - 1] ^= 1
        context["sealed"] = sealed
        #expect(WatchAccountsMessage.content(of: context, key: key) == .unreadable)

        // The key ID is authenticated too: a context relabelled for another key doesn't open with it.
        let other = WatchSyncKey.generate()
        var relabelled = try WatchAccountsMessage.context(for: accounts, key: key)
        relabelled["keyID"] = other.id
        #expect(WatchAccountsMessage.content(of: relabelled, key: other) == .unreadable)
    }

    @Test func noAccountsNeedNoKey() throws {
        let context = try WatchAccountsMessage.context(for: [], key: WatchSyncKey.generate())
        #expect(context["keyID"] == nil && context["sealed"] == nil)
        #expect(WatchAccountsMessage.content(of: context, key: nil) == .cleared)
    }

    /// Only the iPhone reads a version 1 context, to replace it. The watch never takes the accounts from it.
    @Test func anUnencryptedContextIsOnlyReadToReplaceIt() throws {
        let legacy = try legacyContext(accounts)
        #expect(!WatchAccountsMessage.isCurrent(legacy))
        #expect(WatchAccountsMessage.content(of: legacy, key: WatchSyncKey.generate()) == .unreadable)
        #expect(WatchAccountsMessage.legacyAccounts(from: legacy) == accounts)
        #expect(WatchAccountsMessage.legacyAccounts(from: WatchAccountsMessage.clearedContext) == nil)
        #expect(WatchAccountsMessage.isCurrent([:]))
        #expect(WatchAccountsMessage.content(of: [:], key: nil) == .unreadable)
        #expect(WatchAccountsMessage.content(of: ["version": 3, "cleared": true], key: nil) == .unreadable)
    }

    @Test func keyMessages() {
        let key = WatchSyncKey.generate()
        #expect(WatchAccountsMessage.key(from: WatchAccountsMessage.keyMessage(key)) == key)
        #expect(WatchAccountsMessage.key(from: ["key": Data(count: 16)]) == nil)
        #expect(WatchAccountsMessage.key(from: [:]) == nil)
        #expect(WatchAccountsMessage.isKeyRequest(WatchAccountsMessage.keyRequest))
        #expect(!WatchAccountsMessage.isKeyRequest([:]))
        #expect(WatchSyncKey(data: Data(count: 31)) == nil)
        #expect(WatchSyncKey.generate().id != key.id)
    }
}

@MainActor struct WatchAccountReceiverTests {

    private let accountsItem = MemoryKeychainItem()
    private let keyItem = MemoryKeychainItem()
    private let defaults = makeDefaults()
    private let accounts = [account("1"), account("2", issuer: "Apple")]

    private func receiver() -> WatchAccountReceiver {
        WatchAccountReceiver(accountsItem: accountsItem, keyItem: keyItem, defaults: defaults)
    }

    private func saved() throws -> [OTPAccount]? {
        try accountsItem.data.map { try JSONDecoder().decode([OTPAccount].self, from: $0) }
    }

    @Test func appliesAndSavesTheAccounts() throws {
        let key = WatchSyncKey.generate()
        keyItem.write(key.data)
        let receiver = receiver()
        #expect(receiver.apply(try WatchAccountsMessage.context(for: accounts, key: key)) == .applied)
        #expect(receiver.accounts.map(\.id) == ["2", "1"])
        #expect(try saved() == accounts)
        #expect(receiver.isSaved)
        // A new launch shows them from the keychain.
        #expect(self.receiver().accounts.map(\.id) == ["2", "1"])
    }

    @Test func withoutTheKeyTheSavedAccountsStayUntilItComes() throws {
        let old = WatchSyncKey.generate()
        keyItem.write(old.data)
        let receiver = receiver()
        _ = receiver.apply(try WatchAccountsMessage.context(for: [account("old")], key: old))

        let key = WatchSyncKey.generate()
        let context = try WatchAccountsMessage.context(for: accounts, key: key)
        #expect(receiver.apply(context) == .needsKey)
        #expect(receiver.accounts.map(\.id) == ["old"])

        // A key that doesn't match, e.g. an older one, changes nothing.
        #expect(receiver.receive(WatchSyncKey.generate(), context: context) == .needsKey)
        #expect(receiver.accounts.map(\.id) == ["old"])

        #expect(receiver.receive(key, context: context) == .applied)
        #expect(receiver.accounts.map(\.id) == ["2", "1"])
        #expect(keyItem.data == key.data)
    }

    @Test func aFirstContextWithoutAKeyAsksForIt() throws {
        let receiver = receiver()
        #expect(receiver.apply(try WatchAccountsMessage.context(for: accounts, key: WatchSyncKey.generate())) == .needsKey)
        #expect(receiver.accounts.isEmpty)
    }

    @Test func clearingDeletesTheAccountsAndTheKey() throws {
        let key = WatchSyncKey.generate()
        keyItem.write(key.data)
        let receiver = receiver()
        _ = receiver.apply(try WatchAccountsMessage.context(for: accounts, key: key))
        #expect(receiver.apply(WatchAccountsMessage.clearedContext) == .applied)
        #expect(receiver.accounts.isEmpty)
        #expect(accountsItem.data == nil)
        #expect(keyItem.data == nil)
    }

    @Test func anUnencryptedContextIsIgnored() throws {
        let key = WatchSyncKey.generate()
        keyItem.write(key.data)
        let receiver = receiver()
        _ = receiver.apply(try WatchAccountsMessage.context(for: accounts, key: key))
        #expect(receiver.apply(try legacyContext([account("legacy")])) == .unchanged)
        #expect(receiver.apply(try legacyContext([])) == .unchanged)
        #expect(receiver.accounts.map(\.id) == ["2", "1"])
    }

    /// Deleting fails while the watch is locked: the accounts are hidden, and deleted once it is unlocked, also
    /// after a relaunch.
    @Test func clearingWhileLockedIsRetried() throws {
        let key = WatchSyncKey.generate()
        keyItem.write(key.data)
        let receiver = receiver()
        _ = receiver.apply(try WatchAccountsMessage.context(for: accounts, key: key))

        accountsItem.isLocked = true
        keyItem.isLocked = true
        #expect(receiver.apply(WatchAccountsMessage.clearedContext) == .applied)
        #expect(receiver.accounts.isEmpty)
        #expect(!receiver.isSaved)

        let relaunched = self.receiver()
        #expect(relaunched.accounts.isEmpty)
        #expect(relaunched.isClearPending)

        relaunched.retry()
        #expect(relaunched.isClearPending)

        accountsItem.isLocked = false
        keyItem.isLocked = false
        relaunched.retry()
        #expect(!relaunched.isClearPending)
        #expect(accountsItem.data == nil)
        #expect(self.receiver().accounts.isEmpty)
    }

    @Test func accountsReceivedWhileLockedAreSavedLater() throws {
        let key = WatchSyncKey.generate()
        let context = try WatchAccountsMessage.context(for: accounts, key: key)
        let receiver = receiver()
        accountsItem.isLocked = true
        keyItem.isLocked = true
        #expect(receiver.apply(context) == .unchanged)

        // A key from the iPhone is used even though it can't be saved yet.
        #expect(receiver.receive(key, context: context) == .applied)
        #expect(receiver.accounts.map(\.id) == ["2", "1"])
        #expect(!receiver.isSaved)

        accountsItem.isLocked = false
        keyItem.isLocked = false
        receiver.retry()
        #expect(receiver.isSaved)
        #expect(try saved() == accounts)
        #expect(keyItem.data == key.data)
    }

    @Test func aLaunchWhileLockedLoadsOnceUnlocked() throws {
        accountsItem.write(try JSONEncoder().encode(accounts))
        accountsItem.isLocked = true
        let receiver = receiver()
        #expect(receiver.accounts.isEmpty)
        accountsItem.isLocked = false
        receiver.retry()
        #expect(receiver.accounts.map(\.id) == ["2", "1"])
    }

    /// New accounts replace the ones a pending clear was to delete.
    @Test func newAccountsEndAPendingClear() throws {
        let key = WatchSyncKey.generate()
        keyItem.write(key.data)
        accountsItem.write(try JSONEncoder().encode([account("old")]))
        let receiver = receiver()
        accountsItem.isLocked = true
        _ = receiver.apply(WatchAccountsMessage.clearedContext)
        #expect(receiver.isClearPending)

        accountsItem.isLocked = false
        keyItem.write(key.data)
        _ = receiver.apply(try WatchAccountsMessage.context(for: accounts, key: key))
        #expect(receiver.isSaved)
        #expect(try saved() == accounts)
    }
}

#if os(iOS)
    final class FakeWatchSession: WatchSession {

        weak var delegate: (any WCSessionDelegate)?
        var activationState: WCSessionActivationState = .activated
        var isPaired = true
        var isWatchAppInstalled = true
        var isReachable = true
        var applicationContext: [String: Any] = [:]
        var sentMessages: [[String: Any]] = []

        func activate() {}

        func updateApplicationContext(_ applicationContext: [String: Any]) throws {
            self.applicationContext = applicationContext
        }

        func sendMessage(
            _ message: [String: Any], replyHandler: (([String: Any]) -> Void)?,
            errorHandler: ((any Error) -> Void)?
        ) {
            sentMessages.append(message)
        }
    }

    @MainActor struct WatchAccountSyncTests {

        private let session = FakeWatchSession()
        private let keyItem = MemoryKeychainItem()
        private let defaults = makeDefaults()
        private let codes = [
            EnteCodeParser.parse(id: "1", rawData: #""otpauth://totp/GitHub:alice?secret=JBSWY3DPEHPK3PXP""#)!,
            EnteCodeParser.parse(id: "2", rawData: #""otpauth://totp/Zoom:bob?secret=JBSWY3DPEHPK3PXP""#)!
        ]

        private func sync(enabled: Bool = true) -> WatchAccountSync {
            let sync = WatchAccountSync(session: session, keyItem: keyItem, defaults: defaults)
            if enabled { sync.enable() }
            return sync
        }

        private var key: WatchSyncKey? {
            keyItem.data.flatMap(WatchSyncKey.init(data:))
        }

        private var sentAccountIDs: [String]? {
            guard case .accounts(let accounts) = WatchAccountsMessage.content(of: session.applicationContext, key: key)
            else { return nil }
            return accounts.map(\.id)
        }

        @Test func sendsTheAccountsSealedAndTheNewKeyByMessage() throws {
            let sync = sync()
            sync.send(codes)
            let key = try #require(key)
            #expect(sentAccountIDs == ["1", "2"])
            #expect(session.applicationContext["accounts"] == nil)
            #expect(session.sentMessages.count == 1)
            #expect(WatchAccountsMessage.key(from: session.sentMessages[0]) == key)

            // The same key next time, so it isn't sent again.
            sync.send(codes)
            #expect(self.key == key)
            #expect(session.sentMessages.count == 1)
        }

        @Test func theKeyWaitsForTheWatchToAskWhenItIsntReachable() {
            session.isReachable = false
            sync().send(codes)
            #expect(sentAccountIDs == ["1", "2"])
            #expect(session.sentMessages.isEmpty)
        }

        @Test func turningOffClearsTheWatchAndMakesANewKey() throws {
            let sync = sync()
            sync.send(codes)
            let first = try #require(key)

            sync.disable()
            #expect(WatchAccountsMessage.content(of: session.applicationContext, key: nil) == .cleared)
            #expect(keyItem.data == nil)
            #expect(WatchAccountSync.keyReply(keyItem: keyItem, defaults: defaults).isEmpty)

            sync.enable()
            sync.send(codes)
            let second = try #require(key)
            #expect(second != first)
            #expect(sentAccountIDs == ["1", "2"])
        }

        @Test func noAccountsLeftMakesANewKey() throws {
            let sync = sync()
            sync.send(codes)
            let first = try #require(key)
            sync.send([])
            #expect(WatchAccountsMessage.content(of: session.applicationContext, key: nil) == .cleared)
            sync.send(codes)
            #expect(try #require(key) != first)
        }

        /// While the iPhone is locked the key can't be read, so nothing is sent, and no other key replaces it.
        @Test func nothingIsSentWhileTheKeychainIsLocked() throws {
            let sync = sync()
            sync.send(codes)
            let key = try #require(key)
            session.applicationContext = WatchAccountsMessage.clearedContext

            keyItem.isLocked = true
            sync.send(codes)
            #expect(WatchAccountsMessage.content(of: session.applicationContext, key: nil) == .cleared)

            keyItem.isLocked = false
            sync.sessionStateChanged()
            #expect(self.key == key)
            #expect(sentAccountIDs == ["1", "2"])
        }

        /// The key can't be deleted while locked: the watch isn't given it, and it isn't used again.
        @Test func aKeyThatCouldntBeDeletedIsNeverUsedAgain() throws {
            let sync = sync()
            sync.send(codes)
            let first = try #require(key)

            keyItem.isLocked = true
            sync.disable()
            #expect(WatchAccountsMessage.content(of: session.applicationContext, key: nil) == .cleared)

            keyItem.isLocked = false
            sync.enable()
            #expect(WatchAccountSync.keyReply(keyItem: keyItem, defaults: defaults).isEmpty)
            sync.send(codes)
            let second = try #require(key)
            #expect(second != first)
            #expect(sentAccountIDs == ["1", "2"])
            #expect(WatchAccountsMessage.key(from: WatchAccountSync.keyReply(keyItem: keyItem, defaults: defaults)) == second)
        }

        @Test func theWatchIsOnlyGivenTheKeyWhileTheSwitchIsOn() {
            let sync = sync()
            #expect(WatchAccountSync.keyReply(keyItem: keyItem, defaults: defaults).isEmpty)
            sync.send(codes)
            #expect(WatchAccountsMessage.key(from: WatchAccountSync.keyReply(keyItem: keyItem, defaults: defaults)) == key)
            keyItem.isLocked = true
            #expect(WatchAccountSync.keyReply(keyItem: keyItem, defaults: defaults).isEmpty)
        }

        /// A context from an earlier version, with the accounts unencrypted, is replaced as soon as the session is
        /// active.
        @Test func anUnencryptedContextIsReplacedSealed() throws {
            session.applicationContext = try legacyContext([account("1"), account("2", issuer: "Zoom", name: "bob")])
            sync().sessionStateChanged()
            #expect(WatchAccountsMessage.isCurrent(session.applicationContext))
            #expect(session.applicationContext["accounts"] == nil)
            #expect(sentAccountIDs == ["1", "2"])
        }

        @Test func anUnencryptedContextIsClearedWhileTheSwitchIsOff() throws {
            session.applicationContext = try legacyContext([account("1")])
            sync(enabled: false).sessionStateChanged()
            #expect(WatchAccountsMessage.content(of: session.applicationContext, key: nil) == .cleared)
        }

        @Test func anUnencryptedContextIsReplacedOnceTheKeychainIsUnlocked() throws {
            session.applicationContext = try legacyContext([account("1")])
            keyItem.isLocked = true
            let sync = sync()
            sync.sessionStateChanged()
            #expect(!WatchAccountsMessage.isCurrent(session.applicationContext))
            keyItem.isLocked = false
            sync.sessionStateChanged()
            #expect(sentAccountIDs == ["1"])
        }
    }
#endif
