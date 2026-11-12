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
import SafariServices

/// The native side of the Safari extension. The extension's background script asks it for the codes of a website,
/// named by the tab's URL as Safari reports it, never by the page. It answers with the time-based accounts whose AutoFill
/// websites match, from the file the app writes for its AutoFill extension.
///
/// Nothing is given while the app lock is on: this side has no screen to unlock it on, so AutoFill, which has one, is
/// the way to fill in a code then.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {

    nonisolated func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any]
        let host = message?["host"] as? String
        nonisolated(unsafe) let context = context
        Task { @MainActor in
            let response = SafariCodes.response(for: host)
            let reply = NSExtensionItem()
            reply.userInfo = [SFExtensionMessageKey: response]
            context.completeRequest(returningItems: [reply], completionHandler: nil)
        }
    }
}
