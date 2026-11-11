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

@MainActor struct DeviceBackupTests {

    /// Made with PyNaCl the way Ente Auth makes its encrypted export, not with this app's code: Argon2id with 64 MiB
    /// and 2 passes over "correct horse battery", then one final secretstream message.
    private static let enteExport = Data("""
        {"version": 1, "kdfParams": {"memLimit": 67108864, "opsLimit": 2, "salt": "AAECAwQFBgcICQoLDA0ODw=="}, \
        "encryptedData": "+asgMob07PK81by+HSfUkly51SFUiqWz4IIwzSiHIW9Eb7Q06xVIszedoijgR2nqfbhZo4XKm+ZTA9WYxwLYuWWa9xCOorTGhIUdTz/2Pjc4BcBpxbnjeoPM4GaY/ff3ReJGg2J9uhz3RBNovrYPub6rVUHK8V5gYic5oxRiyCWclB9Hcj/9tpzjJZOqlbC8BsEsxRI7TS9e4BhC24ijKmh1qnPmlOvZEf7ngWW4xgyYku2Q0WHFpuaoixLGThnElBCFQH60kfSgU9xDDtcBSqkf0e4wAecfFVsDp3tdbw==", \
        "encryptionNonce": "JCJqXS7Cqemn+NY6xlcoVy8QT+/usKHw"}
        """.utf8)
    private static let entePassword = "correct horse battery"

    private func template(_ issuer: String, hotp: Bool = false) throws -> YubiKitOATHSession.CredentialTemplate {
        let kind = hotp ? "hotp" : "totp"
        let url = try #require(URL(string: "otpauth://\(kind)/\(issuer):alice?secret=JBSWY3DPEHPK3PXP&issuer=\(issuer)" + (hotp ? "&counter=0" : "")))
        return try YubiKitOATHSession.CredentialTemplate(otpauthURL: url)
    }

    /// A file with other values, keeping the rest.
    private func changed(_ data: Data, _ change: (inout [String: Any]) -> Void) throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        change(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test func restoresAnEnteAuthExport() throws {
        let lines = try DeviceBackup.decrypt(Self.enteExport, password: Self.entePassword)
        #expect(lines.count == 2)
        let device = DeviceAccounts(storage: MemoryDeviceStorage())
        #expect(try device.restore(backupLines: lines) == .init(added: 2))

        let github = try #require(device.accounts.first { $0.code.issuer == "GitHub" }?.code)
        #expect(github.accountName == "alice")
        #expect(github.isPinned)
        #expect(github.tags == ["work"])
        #expect(github.secret == OTPAuthURLParser.base32Decode("JBSWY3DPEHPK3PXP"))
        let bank = try #require(device.accounts.first { $0.code.issuer == "Bank" }?.code)
        #expect(bank.kind == .hotp)
        #expect(bank.counter == 7)
    }

    @Test func aWrongPasswordIsToldApartFromAnotherFile() throws {
        #expect(throws: DeviceBackupError.wrongPassword) {
            try DeviceBackup.decrypt(Self.enteExport, password: "correct horse batterz")
        }
        #expect(throws: DeviceBackupError.notABackup) {
            try DeviceBackup.decrypt(Data("otpauth://totp/GitHub:alice?secret=JBSWY3DPEHPK3PXP".utf8), password: "password")
        }
        #expect(DeviceBackup.isBackup(Self.enteExport))
        #expect(!DeviceBackup.isBackup(Data("{}".utf8)))
    }

    @Test func aChangedFileIsRefused() throws {
        let cut = try changed(Self.enteExport) { file in
            let data = Data(base64Encoded: file["encryptedData"] as? String ?? "") ?? Data()
            file["encryptedData"] = data.dropLast().base64EncodedString()
        }
        #expect(throws: DeviceBackupError.wrongPassword) { try DeviceBackup.decrypt(cut, password: Self.entePassword) }
    }

    /// The limits aren't authenticated, so the file can ask for any: cheap ones, or ones that keep the app busy.
    @Test func keyLimitsOutsideEntesAreRefusedBeforeDeriving() throws {
        for (memLimit, opsLimit) in [(8192, 1), (2 * 1024 * 1024 * 1024, 4), (1024 * 1024 * 1024, 1000)] {
            let file = try changed(Self.enteExport) { file in
                file["kdfParams"] = ["memLimit": memLimit, "opsLimit": opsLimit, "salt": "AAECAwQFBgcICQoLDA0ODw=="]
            }
            #expect(throws: DeviceBackupError.unsupported) { try DeviceBackup.decrypt(file, password: Self.entePassword) }
        }
        let later = try changed(Self.enteExport) { $0["version"] = 2 }
        #expect(throws: DeviceBackupError.unsupported) { try DeviceBackup.decrypt(later, password: Self.entePassword) }
    }

    @Test func aBackupRestoresOnAnotherDeviceWithPinsTagsAndCounters() throws {
        let device = DeviceAccounts(storage: MemoryDeviceStorage())
        #expect(try device.add(template("GitHub")) == .added)
        #expect(try device.add(template("Bank", hotp: true)) == .added)
        // A name with what a line of the backup can't hold as it is.
        let odd = try YubiKitOATHSession.CredentialTemplate(type: .totp(period: 30), algorithm: .sha256, secret: Data(repeating: 7, count: 20),
                                                           issuer: "A, B & C #1", accountName: "é+x@example.com", digits: 8)
        #expect(try device.add(odd) == .added)
        let github = try #require(device.accounts.first { $0.code.issuer == "GitHub" })
        device.setPinned(github.id, true)
        try device.setTags(github.id, ["work", "open source"])
        let bank = try #require(device.accounts.first { $0.code.issuer == "Bank" })
        _ = try #require(device.nextHOTPCode(bank.id))

        let password = "a long password"
        let file = try DeviceBackup.encrypt(rawData: device.backupData, password: password)
        // Limits a phone can derive, and Ente's apps take.
        let object = try #require(JSONSerialization.jsonObject(with: file) as? [String: Any])
        let limits = try #require(object["kdfParams"] as? [String: Any])
        #expect(object["version"] as? Int == 1)
        #expect((limits["memLimit"] as? UInt64 ?? .max) <= DeviceBackup.maximumMemory)
        #expect((limits["memLimit"] as? UInt64 ?? 0) * (limits["opsLimit"] as? UInt64 ?? 0) == 4 * 1024 * 1024 * 1024)
        // Nothing of the accounts is readable in the file.
        #expect(!String(decoding: file, as: UTF8.self).contains("JBSWY3DPEHPK3PXP"))
        #expect(!String(decoding: file, as: UTF8.self).contains("GitHub"))

        let lines = try DeviceBackup.decrypt(file, password: password)
        #expect(lines.allSatisfy { $0.hasPrefix("otpauth://") && !$0.contains(",") })
        let other = DeviceAccounts(storage: MemoryDeviceStorage())
        #expect(try other.restore(backupLines: lines) == .init(added: 3))
        #expect(other.accounts.map(\.code) == device.accounts.map(\.code))
        #expect(other.accounts.first { $0.code.issuer == "Bank" }?.code.counter == 1)

        // Restoring it again, or where it was made, adds nothing.
        #expect(try other.restore(backupLines: lines) == .init(alreadyPresent: 3))
        #expect(try device.restore(backupLines: lines) == .init(alreadyPresent: 3))
        #expect(device.accounts.count == 3)
    }

    @Test func restoringKeepsTheAccountsAndCountersThatAreHere() throws {
        let storage = MemoryDeviceStorage()
        let device = DeviceAccounts(storage: storage)
        #expect(try device.add(template("Bank", hotp: true)) == .added)
        let lines = device.backupData.compactMap(DeviceBackup.line(forRawData:))
        #expect(lines.count == 1)
        let id = try #require(device.accounts.first?.id)
        _ = try #require(device.nextHOTPCode(id))
        _ = try #require(device.nextHOTPCode(id))

        let result = try device.restore(backupLines: lines + [
            "otpauth://totp/GitLab:alice?secret=JBSWY3DPEHPK3PXP&issuer=GitLab",
            // The same name with another secret is another account.
            "otpauth://hotp/Bank:alice?secret=GEZDGNBVGY3TQOJQ&issuer=Bank&counter=0",
            "otpauth://totp/Old:alice?secret=JBSWY3DPEHPK3PXP&issuer=Old&codeDisplay=%7B%22trashed%22%3Atrue%7D",
            "not an account",
        ])
        #expect(result == .init(added: 2, alreadyPresent: 1, skipped: 2))
        // The codes before the counter here have been shown.
        #expect(DeviceAccounts(storage: storage).accounts.first { $0.id == id }?.code.counter == 2)
        #expect(DeviceAccounts(storage: storage).accounts.count == 3)
    }

    @Test func nothingIsRestoredIfItCannotBeSaved() throws {
        struct SaveFailed: Error {}
        let storage = MemoryDeviceStorage()
        let device = DeviceAccounts(storage: storage)
        storage.saveError = SaveFailed()
        #expect(throws: SaveFailed.self) {
            try device.restore(backupLines: ["otpauth://totp/GitLab:alice?secret=JBSWY3DPEHPK3PXP&issuer=GitLab"])
        }
        #expect(device.accounts.isEmpty)
    }

    @Test func thereIsNoBackupOfNothing() {
        #expect(throws: DeviceBackupError.noAccounts) { try DeviceBackup.encrypt(rawData: [], password: "a long password") }
        #expect(throws: DeviceBackupError.noAccounts) { try DeviceBackup.encrypt(rawData: ["unreadable"], password: "a long password") }
    }

    @Test func theSummaryLeavesOutWhatDidNotHappen() {
        #expect(!BackupSection.summary(of: .init(added: 2)).contains("\n"))
        #expect(BackupSection.summary(of: .init(added: 2, alreadyPresent: 1, skipped: 1)).split(separator: "\n").count == 3)
    }
}
