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
import YubiKit

@testable import OrielOTP

// Regression tests for the second code review (#149): each one fails without its fix.

/// The plain text of an entity as Ente Auth stores it: the otpauth URL as a JSON string.
nonisolated private func entry(_ uri: String) -> String {
    String(decoding: try! JSONEncoder().encode(uri), as: UTF8.self)
}

nonisolated private func pulled(_ id: String, updatedAt: Int64, isDeleted: Bool = false) -> EnteAuthenticatorEntity {
    EnteAuthenticatorEntity(id: id, encryptedData: nil, header: nil, isDeleted: isDeleted, updatedAt: updatedAt)
}

nonisolated private let secretA = "JBSWY3DPEHPK3PXP"
nonisolated private let secretB = "GEZDGNBVGY3TQOJQ"

// MARK: - The list and the editor read an entity the same way

struct EntityReadingTests {

    /// `%63ounter` is `counter`: an edit replaced nothing and added a second counter, which the list then refused.
    @Test(arguments: ["%63ounter", "COUNTER", "Counter"])
    func anEncodedOrCasedCounterIsReplaced(name: String) throws {
        var editor = try #require(EnteEntryEditor(rawData: entry("otpauth://hotp/A:b?secret=\(secretA)&\(name)=5")))
        #expect(editor.counter == 5)
        editor.counter = 6
        let edited = try #require(editor.rawData)
        #expect(EnteCloudCode(rawData: edited)?.counter == 6)
    }

    @Test func anEncodedIssuerIsReplaced() throws {
        var editor = try #require(EnteEntryEditor(rawData: entry("otpauth://totp/Old:b?secret=\(secretA)&%69ssuer=Old")))
        editor.rename(issuer: "New", accountName: "b")
        let edited = try #require(editor.rawData)
        let code = try #require(EnteCloudCode(rawData: edited))
        #expect(code.issuer == "New")
    }

    /// An account trashed with `CodeDisplay` was listed, and its first edit moved it to the trash everywhere.
    @Test func codeDisplayIsReadInAnyCase() throws {
        let raw = entry(#"otpauth://totp/A:b?secret=JBSWY3DPEHPK3PXP&CodeDisplay=%7B%22trashed%22%3Atrue%7D"#)
        #expect(EnteEntry(rawData: raw).isTrashed)
        #expect(EnteCloudCode(rawData: raw) == nil)
        let editor = try #require(EnteEntryEditor(rawData: raw))
        #expect(editor.isTrashed)
    }

    @Test func theURLsSettingsWinForTheListAndTheEditor() throws {
        let object = #"{"rawData":"otpauth://totp/A:b?secret=JBSWY3DPEHPK3PXP&codeDisplay=%7B%22pinned%22%3Afalse%2C%22trashed%22%3Afalse%7D","display":{"pinned":true,"trashed":true}}"#
        let editor = try #require(EnteEntryEditor(rawData: object))
        let entry = EnteEntry(rawData: object)
        #expect(entry.isPinned == editor.isPinned)
        #expect(entry.isTrashed == editor.isTrashed)
        #expect(!entry.isTrashed)
    }

    /// These were read as 6 digits, 30 seconds or counter 0, which gives wrong codes.
    @Test(arguments: ["totp/A:b?secret=\(secretA)&digits=eight", "totp/A:b?secret=\(secretA)&period=60.0",
                      "totp/A:b?secret=\(secretA)&digits=", "totp/A:b?secret=\(secretA)&period=%2B30",
                      "hotp/A:b?secret=\(secretA)&counter=abc", "hotp/A:b?secret=\(secretA)&digits=6.0"])
    func aValueThatIsntAWholeNumberIsRefused(path: String) {
        #expect(EnteCloudCode(rawData: entry("otpauth://" + path)) == nil)
    }

    @Test func missingValuesUseTheDefaults() throws {
        let totp = try #require(EnteCloudCode(rawData: entry("otpauth://totp/A:b?secret=\(secretA)")))
        #expect((totp.digits, totp.period) == (6, 30))
        let hotp = try #require(EnteCloudCode(rawData: entry("otpauth://hotp/A:b?secret=\(secretA)")))
        #expect(hotp.counter == 0)
    }
}

// MARK: - Merging what other devices changed

struct VaultMergeReviewTests {

    private let server = URL(string: "https://api.example.com")!

    /// A HOTP account given a new secret elsewhere starts at that device's counter, not this one's.
    @Test func aNewSecretTakesItsOwnCounter() throws {
        var vault = EnteVault(email: "a@example.com", server: server)
        vault.merge([(pulled("e1", updatedAt: 1), entry("otpauth://hotp/A:b?secret=\(secretA)&counter=10"))], latest: 1)
        vault.merge([(pulled("e1", updatedAt: 2), entry("otpauth://hotp/A:b?secret=\(secretB)&counter=0"))], latest: 2)
        let code = try #require(vault.items.first?.rawData.flatMap(EnteCloudCode.init(rawData:)))
        #expect(code.counter == 0)
        #expect(vault.items.first?.isPending == false)
    }

    /// The same secret still keeps the higher counter, as its codes have been shown here.
    @Test func theSameSecretKeepsTheHigherCounter() throws {
        var vault = EnteVault(email: "a@example.com", server: server)
        vault.merge([(pulled("e1", updatedAt: 1), entry("otpauth://hotp/A:b?secret=\(secretA)&counter=10"))], latest: 1)
        vault.merge([(pulled("e1", updatedAt: 2), entry("otpauth://hotp/A:c?secret=\(secretA)&counter=3"))], latest: 2)
        let code = try #require(vault.items.first?.rawData.flatMap(EnteCloudCode.init(rawData:)))
        #expect(code.counter == 10)
        #expect(code.accountName == "c")
        #expect(vault.items.first?.isPending == true)
    }

    /// The answer to the upload was lost and another device renamed the account before this one pulled it.
    @Test func aLostCreateEditedElsewhereIsntListedTwice() throws {
        var vault = EnteVault(email: "a@example.com", server: server)
        let raw = entry("otpauth://hotp/A:b?secret=\(secretA)&counter=0")
        let id = vault.add(rawData: raw)
        vault.markUploading(id, rawData: raw)
        let renamed = entry("otpauth://hotp/A:renamed?secret=\(secretA)&counter=0")
        vault.merge([(pulled("e1", updatedAt: 5), renamed)], latest: 5)
        #expect(vault.items.count == 1)
        #expect(vault.items.first?.entityID == "e1")
        #expect(vault.items.first?.rawData == renamed)
        #expect(vault.items.first?.isPending == false)
    }

    /// Another account with a different secret is still a new account.
    @Test func anotherSecretIsAnotherAccount() {
        var vault = EnteVault(email: "a@example.com", server: server)
        let raw = entry("otpauth://totp/A:b?secret=\(secretA)")
        let id = vault.add(rawData: raw)
        vault.markUploading(id, rawData: raw)
        vault.merge([(pulled("e1", updatedAt: 5), entry("otpauth://totp/A:b?secret=\(secretB)"))], latest: 5)
        #expect(vault.items.count == 2)
    }
}

// MARK: - A vault file that can't be read

/// A vault file whose reading fails with `error`, which records what is written to it.
nonisolated final class FailingReadVaultStorage: EnteVaultStorage, @unchecked Sendable {
    private let lock = NSLock()
    private let error: Error
    private(set) var saved: [EnteVault] = []
    private(set) var events: [String] = []

    init(error: Error) {
        self.error = error
    }

    func load() throws -> EnteVault? { throw error }
    func save(_ vault: EnteVault) throws { lock.withLock { saved.append(vault); events.append("save") } }
    func remove() { lock.withLock { events.append("remove") } }
    func setAside() throws { lock.withLock { events.append("setAside") } }
}

@MainActor struct UnreadableVaultTests {

    private let server = URL(string: "https://api.example.com")!

    private func cloud(storage: EnteVaultStorage) throws -> EnteCloud {
        let defaults = makeTestDefaults()
        let store = EnteSessionStore(keychain: InMemoryKeychain(), defaults: defaults, canSave: true)
        try store.save(EnteSavedSession(server: server, email: "alice@example.com", token: "t", authenticatorKey: EnteCrypto.randomBytes(32)))
        return EnteCloud(store: store, storage: storage, session: OfflineURLProtocol.session, watch: WatchAccountSync(defaults: defaults))
    }

    /// A keychain error isn't "no vault": an empty one written over the file would lose what was never uploaded.
    @Test func aKeychainErrorWritesNothing() throws {
        let storage = FailingReadVaultStorage(error: SecureStoreError.unhandledError(message: "-25308"))
        let cloud = try cloud(storage: storage)
        #expect(!cloud.isEnabled)
        #expect(throws: (any Error).self) { _ = try cloud.add(rawData: entry("otpauth://totp/A:b?secret=\(secretA)")) }
        cloud.remove()
        #expect(storage.events.isEmpty)
    }

    /// A file that can't be decoded, e.g. after a downgrade, is set aside before anything is saved, and the error shown.
    @Test func anUndecodableFileIsSetAsideBeforeSaving() throws {
        let storage = FailingReadVaultStorage(error: EnteVaultError.unreadable)
        let cloud = try cloud(storage: storage)
        #expect(cloud.isEnabled)
        #expect(cloud.error != nil)
        _ = try cloud.add(rawData: entry("otpauth://totp/A:b?secret=\(secretA)"))
        #expect(storage.events.first == "setAside")
        #expect(storage.events.dropFirst().allSatisfy { $0 == "save" })
    }

    /// Set aside, not deleted, when signing out.
    @Test func signingOutSetsAnUndecodableFileAside() throws {
        let storage = FailingReadVaultStorage(error: EnteVaultError.unreadable)
        let cloud = try cloud(storage: storage)
        cloud.remove()
        #expect(storage.events == ["setAside", "remove"])
    }

    /// A file set aside comes back once it can be read: its accounts that never reached Ente go to this device.
    @Test func aFileSetAsideIsRecovered() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = InMemoryVaultKey()
        let file = EncryptedFile<EnteVault>(url: folder.appending(path: "Vault"), keychain: key)
        var vault = EnteVault(email: "alice@example.com", server: server)
        _ = vault.add(rawData: entry("otpauth://totp/Only:here?secret=\(secretA)"))
        try file.save(vault)
        try file.setAside()
        #expect(!FileManager.default.fileExists(atPath: file.url.path))

        var recovered: [EnteVault] = []
        file.recoverSetAside { recovered.append($0) }
        #expect(recovered == [vault])
        #expect((try FileManager.default.contentsOfDirectory(atPath: folder.path)).isEmpty)
    }
}

// MARK: - Paging

/// Answers the diff with `count` entities all changed at time 5, at most `limit` of them, like Ente's server.
nonisolated private final class SameTimeDiffStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var count = 0
    nonisolated(unsafe) static var updatedAt: Int64 = 5
    nonisolated(unsafe) static var limits: [Int] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let query = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems ?? []
        let since = query.first { $0.name == "sinceTime" }?.value.flatMap { Int64($0) } ?? 0
        let limit = query.first { $0.name == "limit" }?.value.flatMap { Int($0) } ?? 500
        Self.limits.append(limit)
        let diff: [[String: Any]] = Self.updatedAt > since
            ? (0..<min(Self.count, limit)).map { ["id": "e\($0)", "isDeleted": false, "updatedAt": NSNumber(value: Self.updatedAt)] }
            : []
        let data = (try? JSONSerialization.data(withJSONObject: ["diff": diff])) ?? Data()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct PagingReviewTests {

    private func api() throws -> EnteAPIClient {
        try EnteAPIClient(server: URL(string: "https://ente.test")!, session: URLSession.stubbed([SameTimeDiffStub.self]))
    }

    /// More entities changed at one time than fit a page: a larger page is asked for, rather than stopping.
    @Test func moreAtOneTimeThanAPageAsksForALargerPage() async throws {
        SameTimeDiffStub.count = 1_200
        SameTimeDiffStub.updatedAt = 5
        SameTimeDiffStub.limits = []
        let changes = try await EnteAuthenticatorSync.changes(api: try api(), token: "t", since: 0)
        #expect(changes.entities.count == 1_200)
        #expect(SameTimeDiffStub.limits.max() ?? 0 > EnteAuthenticatorSync.pageSize)
    }

    /// An updatedAt of 0 or less could never be asked for again.
    @Test(arguments: [Int64(0), -5])
    func anUpdatedAtThatCantBeAskedForAgainIsRefused(updatedAt: Int64) async throws {
        SameTimeDiffStub.count = 1
        SameTimeDiffStub.updatedAt = updatedAt
        defer { SameTimeDiffStub.updatedAt = 5 }
        await #expect(throws: EnteAPIError.invalidResponse) {
            _ = try await EnteAuthenticatorSync.changes(api: try api(), token: "t", since: -10)
        }
    }
}

// MARK: - Small fixes

struct SmallReviewFixesTests {

    @Test(arguments: ["https://api.ente.io..", "https://api.ente.io../", "https://ente.io.."])
    func moreThanOneTrailingDotIsRefused(server: String) throws {
        let url = try #require(URL(string: server))
        #expect(EnteAPIClient.host(of: url) == nil)
        #expect(!EnteAPIClient.allowsAccountCreation(on: url))
    }

    /// QR codes in alphanumeric mode are upper case.
    @Test func upperCaseLinksAreRead() throws {
        let url = try #require(URL(string: "OTPAUTH://TOTP/GitHub:alice?SECRET=\(secretA)&issuer=GitHub"))
        #expect(OTPAuthURLParser.isOTPAuth(url))
        let template = try YubiKitOATHSession.CredentialTemplate(otpauthURL: url)
        #expect(template.name == "alice")
    }

    /// One base32 decoder: spaces and dashes are ignored, like a secret typed in groups.
    @Test func base32IgnoresSpacesAndDashes() {
        #expect(Data(base32Encoded: "JBSW Y3DP-EHPK 3PXP") == Data(base32Encoded: secretA))
        #expect(Data(base32Encoded: "JBSW!Y3DP") == nil)
    }

    @Test(arguments: ["1122", "7799", "112233", "1984", "2011", "1225", "2512", "0101", "311299", "122599"])
    func datesYearsAndDoubledDigitsAreEasy(code: String) {
        #expect(AppLockConfiguration.isEasyToGuess(code: code))
    }

    @Test(arguments: ["2749", "8316", "502817", "1357", "135790", "120034", "4073"])
    func otherCodesStillWork(code: String) {
        #expect(!AppLockConfiguration.isEasyToGuess(code: code))
    }
}

// MARK: - Apple Watch

@MainActor struct WatchKeyClearTests {

    /// The key couldn't be deleted while the watch was locked, and nothing tried again.
    @Test func aKeyThatCouldntBeDeletedIsDeletedLater() throws {
        let accountsItem = MemoryKeychainItem()
        let keyItem = MemoryKeychainItem()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let key = WatchSyncKey.generate()
        keyItem.write(key.data)
        let receiver = WatchAccountReceiver(accountsItem: accountsItem, keyItem: keyItem, defaults: defaults)
        let account = OTPAccount(id: "1", kind: .totp, issuer: "GitHub", accountName: "alice", secret: Data(base32Encoded: secretA)!,
                                 algorithm: .sha1, digits: 6, period: 30, isPinned: false)
        _ = receiver.apply(try WatchAccountsMessage.context(for: [account], key: key))

        keyItem.isLocked = true
        #expect(receiver.apply(WatchAccountsMessage.clearedContext) == .applied)
        #expect(!receiver.isSaved)

        // Also after a relaunch.
        let relaunched = WatchAccountReceiver(accountsItem: accountsItem, keyItem: keyItem, defaults: defaults)
        #expect(relaunched.isKeyClearPending)
        keyItem.isLocked = false
        relaunched.retry()
        #expect(keyItem.data == nil)
        #expect(relaunched.isSaved)
    }
}
