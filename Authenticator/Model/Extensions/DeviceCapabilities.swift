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

#if canImport(CoreNFC)
import CoreNFC
#endif

/// The ways this device can connect to a YubiKey.
enum DeviceCapabilities {

    /// NFC reading of ISO 7816 tags, which YubiKeys are.
    static var supportsNFC: Bool {
        #if targetEnvironment(simulator) || !canImport(CoreNFC)
        return false
        #else
        return NFCTagReaderSession.readingAvailable
        #endif
    }

    /// NFC reading of NDEF tags, which is how a YubiKey sends a Yubico OTP over NFC.
    static var supportsNFCScanning: Bool {
        #if targetEnvironment(simulator) || !canImport(CoreNFC)
        return false
        #else
        return NFCNDEFReaderSession.readingAvailable
        #endif
    }


    /// Every Lightning-equipped model that can install iOS/iPadOS 18, the app's oldest. The app doesn't
    /// declare the MFi accessory protocol of Lightning YubiKeys, so these devices only connect to YubiKeys over NFC.
    nonisolated static let hasLightningPort: Bool = {
        #if os(macOS)
        return false
        #else
        var systemInfo = utsname()
        uname(&systemInfo)
        let model = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(validatingCString: $0) ?? ""
            }
        }

        switch model {
        case "iPhone11,2",  // iPhone XS
            "iPhone11,4", "iPhone11,6",  // iPhone XS Max
            "iPhone11,8",  // iPhone XR
            "iPhone12,1",  // iPhone 11
            "iPhone12,3",  // iPhone 11 Pro
            "iPhone12,5",  // iPhone 11 Pro Max
            "iPhone12,8",  // iPhone SE (2nd generation)
            "iPhone13,1",  // iPhone 12 mini
            "iPhone13,2",  // iPhone 12
            "iPhone13,3",  // iPhone 12 Pro
            "iPhone13,4",  // iPhone 12 Pro Max
            "iPhone14,4",  // iPhone 13 mini
            "iPhone14,5",  // iPhone 13
            "iPhone14,2",  // iPhone 13 Pro
            "iPhone14,3",  // iPhone 13 Pro Max
            "iPhone14,6",  // iPhone SE (3rd generation)
            "iPhone14,7",  // iPhone 14
            "iPhone14,8",  // iPhone 14 Plus
            "iPhone15,2",  // iPhone 14 Pro
            "iPhone15,3",  // iPhone 14 Pro Max

            "iPad7,11", "iPad7,12",  // iPad (7th generation)
            "iPad11,6", "iPad11,7",  // iPad (8th generation)
            "iPad12,1", "iPad12,2",  // iPad (9th generation)
            "iPad11,1", "iPad11,2",  // iPad mini (5th generation)
            "iPad11,3", "iPad11,4":  // iPad Air (3rd generation)
            return true

        default:
            return false
        }
        #endif
    }()
}
