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

import Foundation
import YubiKit

// MARK: - The YubiKey's password

extension MainViewModel {

    /// Called by the password alert in MainView.
    func submitPassword(_ password: String) {
        resumePasswordEntry(with: password)
    }

    /// Called when the password alert in MainView is cancelled.
    func cancelPasswordEntry() {
        resumePasswordEntry(with: nil)
    }

    private func resumePasswordEntry(with password: String?) {
        let continuation = passwordEntryContinuation
        passwordEntryContinuation = nil
        continuation?.resume(returning: password)
    }

    /// Called by the save password dialog in MainView. `nil` means "Not now".
    func selectPasswordSaveType(_ type: PasswordSaveType?) {
        let handler = passwordSaveTypeHandler
        passwordSaveTypeHandler = nil
        handler?(type)
    }

    /// Shows the password alert and returns the entered password, or nil if the user cancelled.
    private func requestPassword(isRetry: Bool) async -> String? {
        ConnectionManager.shared.closeNFC(
            errorMessage: String(localized: "Key is password protected", comment: "OATH NFC password protected key"))
        passwordEntryMessage =
            isRetry
            ? String(localized: "Incorrect password. Re-enter password.", comment: "OATH password entry retry")
            : String(
                localized: "To prevent unauthorized access this YubiKey is protected with a password.",
                comment: "OATH password entry enter password")
        // Only one password alert can be shown, an earlier request is treated as cancelled.
        cancelPasswordEntry()
        presentPasswordEntry = true
        return await withCheckedContinuation { passwordEntryContinuation = $0 }
    }

    /// Asks for the password and unlocks the YubiKey with it. Returns false if the user cancelled.
    private func collectPasswordAndUnlock(isRetry: Bool) async throws -> Bool {
        guard let password = await requestPassword(isRetry: isRetry) else { return false }
        let session = try await OATHSessionHandler.shared.anySession()
        let accessKey = try await session.unlock(withPassword: password)
        accessKeyMemoryCache.setAccessKey(accessKey, forKey: session.deviceId)
        handleAccessKeyStorage(accessKey: accessKey, forKey: session.deviceId)
        return true
    }

    /// Unlocks with the cached access key. Returns false if there is none or it didn't work.
    private func unlockWithCachedAccessKey() async -> Bool {
        guard let accessKey = await cachedAccessKey(),
            let session = try? await OATHSessionHandler.shared.anySession()
        else { return false }
        return (try? await session.unlock(withAccessKey: accessKey)) != nil
    }

    func handle(error: Error, retry: (() -> Void)? = nil) {
        if error.isOATHAuthenticationRequired || error.isOATHWrongPassword {
            Task {
                do {
                    if error.isOATHAuthenticationRequired, await unlockWithCachedAccessKey() {
                        retry?()
                    } else if try await collectPasswordAndUnlock(isRetry: error.isOATHWrongPassword) {
                        retry?()
                    }
                } catch {
                    ConnectionManager.shared.closeNFC(errorMessage: String(localized: "Something went wrong"))
                    handle(error: error, retry: retry)
                }
            }
        } else if error.isNFCCancelledByUser {
            // The user dismissed the NFC sheet.
        } else {
            ConnectionManager.shared.closeNFC(errorMessage: LocalizedErrorWrapper(error: error).localizedDescription)
            self.sessionError = error
        }
    }

    private func cachedAccessKey() async -> Data? {
        guard let session = try? await OATHSessionHandler.shared.anySession() else { return nil }
        let keyIdentifier = session.deviceId
        // Check memory cache
        if let accessKey = self.accessKeyMemoryCache.accessKey(forKey: keyIdentifier) {
            return accessKey
        }
        // Finally check key chain
        return try? await self.accessKeySecureStore.getValue(for: keyIdentifier)
    }

    func handleAccessKeyStorage(accessKey: Data, forKey keyIdentifier: String) {
        guard !self.passwordPreferences.neverSavePassword(keyIdentifier: keyIdentifier) else { return }
        Task { [weak self] in
            guard let secureStore = self?.accessKeySecureStore else { return }
            let currentAccessKey: Data? = try? await secureStore.getValue(for: keyIdentifier)
            guard let self, accessKey != currentAccessKey else { return }
            self.presentPasswordSaveType = true
            self.passwordSaveTypeHandler = { [weak self] type in
                guard let type, let self else { return }
                self.passwordPreferences.setPasswordPreference(saveType: type, keyIdentifier: keyIdentifier)
                if type == .save || type == .lock {
                    do {
                        try self.accessKeySecureStore.setValue(
                            accessKey, useAuthentication: self.passwordPreferences.useScreenLock(keyIdentifier: keyIdentifier),
                            for: keyIdentifier)
                    } catch {
                        self.passwordPreferences.resetPasswordPreference(keyIdentifier: keyIdentifier)
                        self.sessionError = error
                    }
                }
            }
        }
    }
}
