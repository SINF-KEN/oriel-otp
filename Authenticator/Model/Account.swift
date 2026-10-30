/*
 * Copyright (C) Yubico.
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

import SwiftUI
import YubiKit

@Observable class Account {

    enum AccountState: Equatable {
        case requiresCalculation
        case countingdown(Double)
        case expired
    }

    /// Where the account is stored and its codes are calculated.
    enum Location: Equatable {
        case yubiKey
        /// In the Ente Auth vault on this device, with the id of the vault item. Its codes are calculated by the app.
        case ente(id: String)
    }

    var otp: OATHSession.OTP?
    var title: String
    var subTitle: String?
    var state: AccountState
    var isPinned: Bool {
        didSet { onPinnedChange?(self) }
    }
    var requiresTouch: Bool
    
    /// Called every time `isPinned` is set.
    @ObservationIgnored var onPinnedChange: ((Account) -> Void)?
    
    var id = UUID()
    /// Identifies the account in the list. An account can be on the YubiKey and in Ente Auth with the same name.
    var accountId: String {
        switch location {
        case .yubiKey: credential.id
        case .ente(let id): "ente/" + id
        }
    }
    var credential: OATHSession.Credential
    let location: Location
    /// An Ente Auth account changed here that hasn't been uploaded yet.
    var isPendingSync = false
    var keyVersion: Version
    var color: Color = .red
    var enableRefresh: Bool = true
    @ObservationIgnored private var timeLeft: Double?
    @ObservationIgnored private var requestRefresh: (Account) -> Void
    @ObservationIgnored private var connectionType: OATHSession.ConnectionType
    @ObservationIgnored private var calculateCompletion: ((OATHSession.OTP) -> ())? = nil
    
    init(credential: OATHSession.Credential, code: OATHSession.OTP?, keyVersion: Version, requestRefresh: @escaping (Account) -> Void, connectionType: OATHSession.ConnectionType, isPinned: Bool, location: Location = .yubiKey) {

        self.credential = credential
        self.location = location
        title = credential.title
        subTitle = credential.subTitle
        self.isPinned = isPinned
        self.keyVersion = keyVersion
        self.requiresTouch = credential.requiresTouch
        
        if code == nil {
            enableRefresh = true
            state = .requiresCalculation
        } else {
            enableRefresh = false
            state = .countingdown(1.0)
        }
        self.connectionType = connectionType
        self.requestRefresh = requestRefresh
        self.update(otp: code)
    }
    
    func calculate(completion: ((OATHSession.OTP) -> ())? = nil) {
        calculateCompletion = completion
        requestRefresh(self)
    }
    
    var isInEnte: Bool { location != .yubiKey }

    /// Renaming on a YubiKey needs firmware 5.3 or later.
    var canRename: Bool { isInEnte || keyVersion >= Version("5.3.0")! }

    func updateTitles() {
        title = credential.title
        subTitle = credential.subTitle
    }
    
    func update(otp: OATHSession.OTP?) {
        guard self.otp != otp, let otp else { return }
        self.otp = otp
        
        if let calculateCompletion {
            calculateCompletion(otp)
        }
        self.calculateCompletion = nil
        
        if self.credential.type == .totp {
            self.timeLeft = otp.validity.end.timeIntervalSince(AppClock.now)
            
            // Schedule refresh if connection is wired
            if let timeLeft, connectionType == .wired {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(max(timeLeft, 0)))
                    guard let self else { return }
                    self.requestRefresh(self)
                }
            }
            updateState()
        } else {
            self.state = .requiresCalculation
        }
    }
    
    var formattedCode: String? {
        guard let otp else { return nil }
        if self.credential.isSteam {
            return otp.code
        } else {
            // make it pretty by splitting in halves
            var formattedCode = otp.code
            formattedCode.insert(" ", at:  formattedCode.index(formattedCode.startIndex, offsetBy: formattedCode.count / 2))
            return formattedCode
        }
    }
    
    var iconColor: Color {
#if DEBUG
        // return hard coded nice looking colors for app store screen shots
        switch self.title {
        case "Twitter":
            return Color("Color5")
        case "Microsoft":
            return Color("Color7")
        case "GitHub":
            return Color("Color8")
        default:
            break
        }
#endif
        let value = abs(accountId.hash) % Color.colorSetForAccountIcons.count
        return Color.colorSetForAccountIcons[value]
    }

    func updateState() {
        guard credential.type == .totp else {
            self.enableRefresh = true
            self.state = .requiresCalculation
            return
        }

        if let validInterval = otp?.validity {
            let timeLeft = validInterval.end.timeIntervalSince(AppClock.now)
            self.timeLeft = timeLeft
            if timeLeft > 0 {
                self.state = .countingdown(timeLeft / validInterval.duration)
                self.enableRefresh = false
            } else if timeLeft < 0 {
                self.state = .expired
                self.enableRefresh = true
            } else if connectionType == .nfc {
                self.state = .expired
                self.enableRefresh = true
            }
        }
    }
}

extension Account: Comparable {
    static func == (lhs: Account, rhs: Account) -> Bool {
        return lhs.accountId.lowercased() == rhs.accountId.lowercased()
    }

    /// By name, the YubiKey's account first when the same name is in Ente Auth too.
    static func < (lhs: Account, rhs: Account) -> Bool {
        return (lhs.credential.id.lowercased(), lhs.isInEnte ? 1 : 0, lhs.accountId.lowercased())
            < (rhs.credential.id.lowercased(), rhs.isInEnte ? 1 : 0, rhs.accountId.lowercased())
    }
}

extension OATHSession.Credential {
    var title: String {
        if let issuer, issuer.isEmpty == false {
            return issuer
        } else {
            return accountName
        }
    }
    var subTitle: String? {
        if issuer != nil && issuer?.isEmpty == false {
            return accountName
        } else {
            return nil
        }
    }
}
