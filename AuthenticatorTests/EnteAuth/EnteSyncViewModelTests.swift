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

@testable import Authenticator

struct EnteSyncViewModelTests {

    private func code(_ issuer: String) -> EnteCode {
        EnteCodeParser.parse(id: issuer, rawData: #""otpauth://totp/\#(issuer):alice?secret=JBSWY3DPEHPK3PXP&issuer=\#(issuer)""#)!
    }

    private func model(codes: [String], onYubiKey: [String] = [], capacity: Int?) -> EnteSyncViewModel {
        let existing = Set(onYubiKey.map { "\($0):alice" })
        let model = EnteSyncViewModel(existingCredentialIds: existing, capacity: capacity,
                                      store: EnteSessionStore(service: "EnteSyncViewModelTests"),
                                      defaults: UserDefaults(suiteName: "EnteSyncViewModelTests")!)
        model.codes = codes.map(code)
        return model
    }

    @Test func selectAllSelectsEverythingWhenTheCapacityIsUnknown() {
        let model = model(codes: ["A", "B", "C"], capacity: nil)
        model.selectAll()
        #expect(model.selection == ["A", "B", "C"])
        #expect(model.freeSpaces == nil)
        #expect(!model.isSelectionTooLarge)
        #expect(!model.canSelectMore)
    }

    @Test func selectAllStopsWhenTheYubiKeyIsFull() {
        // Two of four spaces are taken, so only the first two importable accounts are selected.
        let model = model(codes: ["A", "B", "C", "D"], onYubiKey: ["X", "Y"], capacity: 4)
        model.selectAll()
        #expect(model.freeSpaces == 2)
        #expect(model.selection == ["A", "B"])
        #expect(!model.isSelectionTooLarge)
        #expect(!model.canSelectMore)
    }

    @Test func accountsAlreadyOnTheYubiKeyDontTakeSpace() {
        let model = model(codes: ["A", "B", "C"], onYubiKey: ["A"], capacity: 3)
        model.selectAll()
        #expect(model.freeSpaces == 2)
        #expect(model.selection == ["B", "C"])
    }

    @Test func selectingPastTheCapacityIsFlagged() {
        let model = model(codes: ["A", "B", "C"], capacity: 2)
        model.selectAll()
        model.toggleSelection(model.codes[2])
        #expect(model.selection.count == 3)
        #expect(model.isSelectionTooLarge)
        model.toggleSelection(model.codes[0])
        #expect(!model.isSelectionTooLarge)
    }

    @Test func aFullYubiKeySelectsNothing() {
        let model = model(codes: ["A"], onYubiKey: ["X", "Y"], capacity: 2)
        model.selectAll()
        #expect(model.freeSpaces == 0)
        #expect(model.selection.isEmpty)
        #expect(!model.canSelectMore)
    }

    @Test func partialSelectionCanSelectMore() {
        let model = model(codes: ["A", "B", "C"], capacity: 32)
        model.toggleSelection(model.codes[0])
        #expect(model.canSelectMore)
    }

    @Test func capacityFollowsTheFirmwareVersion() {
        #expect(OATHSession.credentialCapacity(version: Version("5.7.0")!) == 64)
        #expect(OATHSession.credentialCapacity(version: Version("5.7.4")!) == 64)
        #expect(OATHSession.credentialCapacity(version: Version("5.4.3")!) == 32)
        #expect(OATHSession.credentialCapacity(version: Version("4.3.7")!) == 32)
        #expect(OATHSession.credentialCapacity(version: Version("0.2.1")!) == 28)
    }

    @Test func storageFullErrorNamesTheAccountsLeftOut() {
        let error = OATHSessionError.storageFull(notAdded: ["GitHub (alice)", "Dropbox"])
        let description = error.errorDescription ?? ""
        #expect(description.contains("GitHub (alice)"))
        #expect(description.contains("Dropbox"))
    }
}
