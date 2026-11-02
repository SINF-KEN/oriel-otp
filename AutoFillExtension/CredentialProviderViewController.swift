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

import AuthenticationServices
import SwiftUI

/// Fills in the codes of the Ente Auth accounts the app keeps for AutoFill, from the list of codes or a suggestion
/// above the keyboard. With App Lock on, the app's lock is asked for first.
final class CredentialProviderViewController: ASCredentialProviderViewController {

    private let model = AutoFillModel()

    #if os(macOS)
    override func loadView() {
        view = NSView()
        preferredContentSize = NSSize(width: 420, height: 520)
    }
    #endif

    override func viewDidLoad() {
        super.viewDidLoad()
        model.fill = { [weak self] in self?.fill($0) }
        model.cancel = { [weak self] in self?.cancel(.userCanceled) }
        #if os(iOS)
        let host = UIHostingController(rootView: AutoFillView(model: model))
        #else
        let host = NSHostingController(rootView: AutoFillView(model: model))
        #endif
        addChild(host)
        host.view.frame = view.bounds
        #if os(iOS)
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        #else
        host.view.autoresizingMask = [.width, .height]
        #endif
        view.addSubview(host.view)
        #if os(iOS)
        host.didMove(toParent: self)
        #endif
    }

    /// The list of codes, from the key button above the keyboard or the AutoFill menu.
    override func prepareOneTimeCodeCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        model.load(for: serviceIdentifiers)
    }

    /// A suggestion was chosen. Without App Lock its code is filled in right away.
    override func provideCredentialWithoutUserInteraction(for credentialRequest: any ASCredentialRequest) {
        guard !AppLock.shared.isLocked else {
            cancel(.userInteractionRequired)
            return
        }
        model.load(for: [])
        guard let account = model.account(for: credentialRequest) else {
            cancel(.credentialIdentityNotFound)
            return
        }
        fill(account)
    }

    /// A suggestion was chosen with App Lock on: the lock is shown, and the code filled in once it's unlocked.
    override func prepareInterfaceToProvideCredential(for credentialRequest: any ASCredentialRequest) {
        model.load(for: [])
        guard let account = model.account(for: credentialRequest) else {
            cancel(.credentialIdentityNotFound)
            return
        }
        model.pending = account
    }

    /// AutoFill from Oriel OTP was turned on in Settings: its suggestions are added without opening the app.
    override func prepareInterfaceForExtensionConfiguration() {
        Task {
            if let accounts = try? AutoFillFile().load() {
                await AutoFillIdentities.replace(with: accounts)
            }
            extensionContext.completeExtensionConfigurationRequest()
        }
    }

    private func fill(_ account: AutoFillAccount) {
        let code = OTPGenerator.code(for: account.account, at: .now)
        extensionContext.completeOneTimeCodeRequest(using: ASOneTimeCodeCredential(code: code))
    }

    private func cancel(_ code: ASExtensionError.Code) {
        extensionContext.cancelRequest(withError: ASExtensionError(code))
    }
}
