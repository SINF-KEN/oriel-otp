/*
 * Copyright (C) 2022 Yubico.
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

struct ConfigurationView: View {
    @State var model = ConfigurationViewModel()
    @Binding var showConfiguration: Bool
    @State var showInsertYubiKey: Bool = false
    @Environment(\.accessibilityVoiceOverEnabled) var isVoiceOverEnabled
    
    // Computed so it follows VoiceOver being turned on or off while the app runs.
    var insertYubiKeyMessage: String {
        .insertYubiKey(isVoiceOverEnabled: isVoiceOverEnabled)
    }
    
    var body: some View {
        NavigationStack {
            SettingsList {
                if model.deviceInfo == nil {
                    VStack(alignment: .center) {
                        Image("InsertKey")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 100, height: 100)
                            .padding(15)
                            .accessibilityHidden(true)
                        Text(insertYubiKeyMessage)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 10)
                    .padding(.horizontal, 20)
                    .listRowBackground(Color.black.opacity(0))
                }
                
                if let deviceInfo = model.deviceInfo {
                    Section {
                        VStack(alignment: .center) {
                            if let image = deviceInfo.deviceImage {
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 150, height: 150)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        if let deviceName = model.deviceName {
                            LabeledContent {
                                Text(deviceName)
                            } label: {
                                HStack {
                                    ListIconView(image: Image("securitykey"), color: Color(.systemGray))
                                    Text("Device type")
                                }
                            }
                        }
                        LabeledContent {
                            Text(String(deviceInfo.serialNumber))
                        } label: {
                            HStack {
                                ListIconView(image: Image(systemName: "number"), color: Color(.systemGray), padding: 7)
                                Text("Serial number")
                            }
                        }
                        LabeledContent {
                            Text(deviceInfo.firmwareDescription)
                        } label: {
                            HStack {
                                ListIconView(image: Image(systemName: "cpu"), color: Color(.systemGray), padding: 5)
                                Text("Firmware version")
                            }
                        }
                    }
                }
                Section("General") {
                    ConfigurationLink {
                        OTPConfigurationView()
                            .navigationBarTitleDisplayMode(.inline)
                            .navigationTitle("Toggle One-Time Password")
                            .onDisappear {
                                model.start()
                            }
                    } label: {
                        ListIconView(image: Image(systemName: "ellipsis.rectangle"), color: Color(.systemBlue))
                        Text("Toggle One-Time Password")
                    }
                    if DeviceCapabilities.supportsNFCScanning {
                        ConfigurationLink {
                            NFCSettingsView()
                                .navigationBarTitleDisplayMode(.inline)
                                .navigationTitle("NFC settings")
                                .onDisappear {
                                    model.start()
                                }
                        } label: {
                            ListIconView(image: Image(systemName: "dot.radiowaves.left.and.right"), color: Color(.systemBlue))
                            Text("NFC settings")
                        }
                    }
                }
                Section("OATH") {
                    if let storage = model.oathStorage {
                        OATHStorageRow(storage: storage)
                    }
                    ConfigurationLink {
                        OATHPasswordView()
                            .onDisappear {
                                model.start()
                            }
                    } label: {
                        ListIconView(image: Image(systemName: "lock.shield"), color: Color(.systemPurple))
                        Text("Manage password")
                    }
                    ConfigurationLink {
                        OATHSavedPasswordsView()
                    } label: {
                        ListIconView(image: Image(systemName: "xmark.circle"), color: Color(.systemPink), padding: 5)
                        Text("Clear saved passwords")
                    }
                    ConfigurationLink {
                        OATHResetView()
                            .onDisappear {
                                model.start()
                            }
                    } label: {
                        ListIconView(image: Image(systemName: "trash"), color: Color(.systemRed), padding: 5)
                        Text("Reset OATH application")
                    }
                }
                if DeviceCapabilities.supportsFIDO {
                    Section("FIDO") {
                        ConfigurationLink {
                            FIDOPINView()
                                .onDisappear {
                                    model.start()
                                }
                        } label: {
                            ListIconView(image: Image(systemName: "lock.shield"), color: Color(.systemPurple))
                            Text("Manage PIN")
                        }
                        ConfigurationLink {
                            FIDOResetView {
                                Task {
                                    model.start()
                                }
                            }
                        } label: {
                            ListIconView(image: Image(systemName: "trash"), color: Color(.systemRed), padding: 5)
                            Text("Reset FIDO application")
                        }
                    }
                }
                #if os(iOS)
                // The Mac reads the PIV certificates with its own smart card driver.
                Section("PIV") {
                    ConfigurationLink {
                        SmartCardConfigurationView()
                            .onDisappear {
                                model.start()
                            }
                    } label: {
                        ListIconView(image: Image(systemName: "creditcard"), color: Color(.systemOrange))
                        Text("Smart card extension")
                    }
                }
                // The Mac shows the app lock, AutoFill and the Ente account in the General tab of its Settings window.
                AppLockSection()
                PrivacySection()
                BackupSection()
                AutoFillSection()
                EnteAccountSection()
                #endif
            }
            #if os(iOS)
            // On the Mac the Settings window is titled after the tab.
            .navigationTitle(String(localized: "Configuration", comment: "Configuration navigation title"))
            // Like most sheets. With a large title this one fails the accessibility audit on an iPad, whose sheets end
            // above the bottom of the screen, at the largest text sizes, where the title also takes room from the rows.
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityAction(.escape) { showConfiguration.toggle() }
            #endif
            .toolbar {
                #if os(iOS)
                // A tab of the Settings window on the Mac, which has its own close button.
                ToolbarItem(placement: .cancellationAction) {
                    CloseButton { showConfiguration.toggle() }
                }
                #endif
                // Always there, so scanning doesn't depend on discovering pull to refresh.
                if DeviceCapabilities.supportsNFC {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            model.scanNFC()
                        } label: {
                            Label(String(localized: "Scan NFC YubiKey"), systemImage: "wave.3.right")
                        }
                        .accessibilityInputLabels(VoiceControlNames.scanNFC)
                    }
                }
            }
        }
        .onChange(of: model.deviceInfo == nil) { _, _ in
            withAnimation(.unlessReduceMotion) {
                showInsertYubiKey = model.deviceInfo == nil
            }
        }
        .onAppear {
            withAnimation(.unlessReduceMotion) {
                showInsertYubiKey = model.deviceInfo == nil
            }

            model.start()
        }
        .refreshable(enabled: DeviceCapabilities.supportsNFC) {
            model.scanNFC()
        }
    }
}

/// A row that opens a page of the configuration. iOS pushes the page. On the Mac it's a sheet: the configuration is a tab
/// of the Settings window, where a pushed page takes over the window's toolbar, with its back button among the tabs and
/// its title in place of the tab's.
private struct ConfigurationLink<Destination: View, Label: View>: View {
    @ViewBuilder let destination: () -> Destination
    @ViewBuilder let label: () -> Label
    #if os(macOS)
    @State private var isPresented = false
    #endif

    var body: some View {
        #if os(macOS)
        Button {
            isPresented = true
        } label: {
            HStack {
                label()
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $isPresented) {
            NavigationStack {
                destination()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            CloseButton { isPresented = false }
                                .keyboardShortcut(.cancelAction)
                        }
                    }
            }
            .textScaledFrame(width: 480, height: 360)
            .scaledBodyFont()
            .appLockCover()
        }
        #else
        NavigationLink(destination: destination, label: label)
        #endif
    }
}

/// How many accounts the YubiKey has, and how many more it can take.
private struct OATHStorageRow: View {
    let storage: ConfigurationViewModel.OATHStorage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent {
                if let used = storage.used, let free = storage.free {
                    Text(String(localized: "\(used) of \(storage.capacity) used", comment: "YubiKey OATH storage. The placeholders are the number of accounts and how many fit."))
                        .accessibilityValue(String(localized: "\(free) free", comment: "YubiKey OATH storage, for VoiceOver. The placeholder is the number of accounts that still fit."))
                } else {
                    Text(String(localized: "Locked with a password", comment: "YubiKey OATH storage of a YubiKey whose password isn't saved"))
                }
            } label: {
                HStack {
                    ListIconView(image: Image(systemName: "person.2"), color: Color(.systemPurple), padding: 5)
                    Text(String(localized: "Accounts", comment: "YubiKey OATH storage"))
                }
            }
            .accessibilityIdentifier("configuration.oath-storage")
            if let used = storage.used {
                // Read out in the row above.
                ProgressView(value: Double(min(used, storage.capacity)), total: Double(storage.capacity))
                    .tint(used >= storage.capacity ? Color(.systemRed) : Color(.systemPurple))
                    .accessibilityHidden(true)
                if let free = storage.free {
                    Text(free == 0 ? String(localized: "The YubiKey is full. Delete an account to add another.", comment: "YubiKey OATH storage when full")
                         : String(localized: "Room for \(free) more accounts.", comment: "YubiKey OATH storage. The placeholder is the number of accounts that still fit."))
                        .scaledFont(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct ListIconView: View {

    @Environment(\.textScale) private var textScale
    var image: Image
    var color: Color
    var padding: CGFloat = 4.3
    
    var body: some View {
        image
            .resizable()
            .scaledToFit()
            .scaledFont(.title) { $0.weight(.semibold) }
            .padding(padding * textScale)
            // Grows with the Mac's text size. On iOS it stays the size of the system's settings icons.
            .frame(width: 29 * textScale, height: 29 * textScale)
            .foregroundStyle(.white)
            .background(color)
            .clipShape(.rect(cornerRadius: 6.5))
            // Beside the row's title, which says what it is.
            .accessibilityHidden(true)
    }
}

extension DeviceInfo {
    /// The firmware version, with the release stage and build of prerelease firmware.
    var firmwareDescription: String {
        Self.firmwareDescription(version: version, releaseType: versionQualifier.releaseType, iteration: versionQualifier.iteration)
    }

    static func firmwareDescription(version: Version, releaseType: VersionQualifier.ReleaseType, iteration: UInt32) -> String {
        switch releaseType {
        case .alpha:
            return "\(version)-alpha.\(iteration)"
        case .beta:
            return "\(version)-beta.\(iteration)"
        case .final:
            return version.description
        }
    }

    var deviceImage: Image? {
        switch formFactor {
        case .usbAKeychain:
            return Image("key-usba")
        case .usbCKeychain:
            return Image("key-usbc")
        case .usbCLightning:
            return Image("key-usbc-lightning")
        case .usbCBio:
            return Image("key-bio-usbc")
        case .usbABio:
            return Image("key-bio-usba")
        default:
            return nil
        }
    }
}
