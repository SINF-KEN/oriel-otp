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

/// What the Safari extension gets for a website.
enum SafariCodes {

    static func response(
        for host: String?, storage: AutoFillStorage = AutoFillFile(),
        isLocked: () -> Bool = {
            AppLock.shared.relock()
            return AppLock.shared.isLocked
        }, now: Date = .now
    ) -> [String: Any] {
        guard let host = host?.lowercased(), !host.isEmpty else { return ["error": "noWebsite"] }
        guard !isLocked() else { return ["error": "locked"] }
        let accounts: [AutoFillAccount]
        do {
            accounts = try storage.load() ?? []
        } catch {
            return ["error": "unavailable"]
        }
        guard !accounts.isEmpty else { return ["error": "noAccounts"] }
        let matching =
            accounts
            .filter { $0.websites.contains { AutoFillWebsites.matches(host: host, website: $0) } }
            .sorted { OTPAccount.listOrder($0.account, $1.account) }
        return [
            "accounts": matching.map { account in
                [
                    "title": account.account.title,
                    "subtitle": account.account.subtitle ?? "",
                    "code": OTPGenerator.code(for: account.account, at: now)
                ]
            }
        ]
    }
}
