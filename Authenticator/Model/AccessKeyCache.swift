/*
 * Copyright (C) 2022 Yubico.
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

struct AccessKeyCache {
    
    let timeToLive = TimeInterval(5*60)
    
    struct AccessKey {
        let timeStamp: Date
        let accessKey: Data
        
        init(_ accessKey: Data, timeStamp: Date = Date()) {
            self.accessKey = accessKey
            self.timeStamp = timeStamp
        }
    }
    
    private var cache = [String: AccessKey]()
    
    // Reading a key restarts its time to live. `now` is only passed by the tests.
    mutating func accessKey(forKey index: String, now: Date = Date()) -> Data? {
        guard let possibleAccessKey = cache[index] else { return nil }
        if now < Date(timeInterval: timeToLive, since: possibleAccessKey.timeStamp) {
            cache[index] = AccessKey(possibleAccessKey.accessKey, timeStamp: now)
            return possibleAccessKey.accessKey
        } else {
            cache.removeValue(forKey: index)
            return nil
        }
    }
    
    mutating func setAccessKey(_ accessKey: Data, forKey index: String, now: Date = Date()) {
        cache[index] = AccessKey(accessKey, timeStamp: now)
    }
}
