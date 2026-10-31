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

extension String {

    /// The account name to show, kept left to right when it's an email address.
    ///
    /// An address that starts with Arabic or Hebrew, like "علي@example.com", would otherwise be laid out right to left
    /// and show as "example.com@علي". Only for showing: the isolate characters around it would break searching, copying
    /// and comparing.
    ///
    /// This file is shared by the iPhone app and the watch app.
    var leftToRightIfAddress: String {
        guard contains("@"), !contains(where: \.isWhitespace) else { return self }
        // Left-to-right isolate and pop directional isolate, so the name around it keeps its own direction.
        return "\u{2066}\(self)\u{2069}"
    }
}
