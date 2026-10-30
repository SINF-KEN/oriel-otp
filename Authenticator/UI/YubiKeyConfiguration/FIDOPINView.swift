//
//  OATHPasswordView.swift
//  Authenticator
//
//  Created by Jens Utbult on 2024-08-22.
//  Copyright © 2024 Yubico. All rights reserved.
//  Copyright © 2026 Kenzi Voyer.
//

import SwiftUI

struct FIDOPINView: View {
    
    @State var model = FIDOPINViewModel()
    @Environment(\.dismiss) private var dismiss

    @State var presentSetPIN = false
    @State var presentChangePIN = false
    @State var presentErrorAlert = false
    
    @State var error: Error? = nil
    
    @State var showSetButton = true
    @State var showChangeButton = false
    
    func areButtonsDisabled() -> Bool {
        model.state == .unknown || model.state.isFatalError() || model.isProcessing || model.state.isBlocked() || model.state.isPermanentlyBlocked()
    }

    var body: some View {
        SettingsView(image: Image(systemName: "lock.shield"), imageColor: Color(.systemPurple)) {
            Text("FIDO PIN").font(.title2).bold()
                .accessibilityAddTraits(.isHeader)

            Text("To prevent unauthorized access the FIDO application can be protected by a PIN.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
            
            // With a symbol, so it doesn't take the red to see it's a problem.
            if model.state.isBlocked() {
                Label {
                    Text("PIN is temporary blocked. Remove and reinsert YubiKey to try again.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.subheadline)
                .foregroundStyle(.red)
                .bold()
                .multilineTextAlignment(.center)
            }
            if model.state.isPermanentlyBlocked() {
                Label {
                    Text("PIN is permanently blocked. Factory reset FIDO application to continue.")
                } icon: {
                    Image(systemName: "exclamationmark.octagon.fill")
                }
                .font(.subheadline)
                .foregroundStyle(.red)
                .bold()
                .multilineTextAlignment(.center)
            }
        } buttons: {
            if showSetButton {
                SettingsButton(String(localized: "Set PIN")) {
                    presentSetPIN.toggle()
                }.disabled(areButtonsDisabled())
            }
            if showChangeButton {
                SettingsButton(String(localized: "Change PIN")) {
                    presentChangePIN.toggle()
                }.disabled(areButtonsDisabled())
            }
        }
        .navigationTitle(Text("FIDO PIN"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $presentSetPIN) {
            FIDOSetChangePINView(type: .set)
        }
        .sheet(isPresented: $presentChangePIN) {
            FIDOSetChangePINView(type: .change)
        }
        .alert(error?.localizedDescription ?? String(localized: "Unknown error"), isPresented: $presentErrorAlert, actions: {
            Button(role: .cancel) {
                error = nil
                if model.state.isFatalError() {
                    dismiss()
                }
            } label: {
                Text("OK")
            }
        })
        .onChange(of: model.state) { _, state in
            updateState()
        }
        .onAppear {
            model.load()
            updateState()
        }
        .environment(model)
    }
    
    func updateState() {
        withAnimation(.unlessReduceMotion) {
            switch model.state {
            case .unknown:
                break
            case .notSet:
                self.showSetButton = true
                self.showChangeButton = false
            case .set, .didSet, .didChange:
                self.showSetButton = false
                self.showChangeButton = true
            case .error(let error):
                guard presentSetPIN == false && presentChangePIN == false else { return }
                presentErrorAlert = true
                self.error = error
            case .keyRemoved:
                dismiss()
            }
        }
    }
}

struct FIDOSetChangePINView: View {
    
    enum Action { case set, change }
    var type: Action
    
    @Environment(\.dismiss) private var dismiss
    
    @Environment(FIDOPINViewModel.self) var model
    @FocusState private var focusedField: FocusedField?

    enum FocusedField {
        case currentPIN, newPIN, repeatedPIN
    }
    
    @State private var currentPIN: String = ""
    @State private var newPIN: String = ""
    @State private var repeatedPIN: String = ""
    
    @State private var presentErrorAlert = false
    @State private var errorMessage: String? = nil
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if type == .change {
                        LabeledContent {
                            SecureField(text: $currentPIN, prompt: Text("enter current PIN")) {
                                Text("Current PIN")
                            }
                            .submitLabel(.next)
                            .focused($focusedField, equals: .currentPIN)
                        } label: {
                            Text("Current PIN")
                        }
                    }
                    LabeledContent {
                        SecureField(text: $newPIN, prompt: Text("enter PIN")) {
                            Text("New")
                        }
                        .submitLabel(.next)
                        .focused($focusedField, equals: .newPIN)
                    } label: {
                        Text("New")
                    }
                    LabeledContent {
                        SecureField(text: $repeatedPIN, prompt: Text("re-enter PIN")) {
                            Text("Verify")
                        }
                        .submitLabel(.return)
                        .focused($focusedField, equals: .repeatedPIN)
                    } label: {
                        Text("Verify")
                    }
                } footer: {
                    Text( "\(model.pincomplexity ? String(localized: "A PIN must be at least \(model.minPinLength) characters long, contain at least 2 unique characters, and not be a commonly used PIN, like \"123456\". It may contain letters, numbers and special characters.") : String(localized: "A PIN must be at least \(model.minPinLength) characters long and may contain letters, numbers and special characters."))")
                }
                .onSubmit {
                    if focusedField == .currentPIN {
                        focusedField = .newPIN
                    } else if focusedField == .newPIN {
                        focusedField = .repeatedPIN
                    } else {
                        focusedField = nil
                        setNewPin()
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(type == .set ? String(localized: "Set PIN") : String(localized: "Change PIN"))
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityAction(.escape) { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CancelButton { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    ConfirmButton(String(localized: "Set")) { setNewPin() }
                }
            }
            .onAppear {
                focusedField = type == .set ? .newPIN : .currentPIN
            }
            .onChange(of: model.state) { _, state in
                switch model.state {
                case .error(let error):
                    self.errorMessage = LocalizedErrorWrapper(error: error).localizedDescription
                    self.currentPIN = ""
                    self.newPIN = ""
                    self.repeatedPIN = ""
                    presentErrorAlert = true
                case .didSet, .didChange:
                    dismiss()
                default: break
                }
            }
            .alert(errorMessage ?? String(localized: "Unknown error"), isPresented: $presentErrorAlert, actions: {
                Button(role: .cancel) {
                    errorMessage = nil
                    if model.state.isFatalError() {
                        dismiss()
                    }
                } label: {
                    Text("OK")
                }
            })
        }
    }
    
    private func presentValidationError(_ message: String) {
        errorMessage = message
        presentErrorAlert.toggle()
        currentPIN = ""
        newPIN = ""
        repeatedPIN = ""
        focusedField = type == .set ? .newPIN : .currentPIN
    }
    
    private func setNewPin() {
        guard newPIN == repeatedPIN else {
            presentValidationError(String(localized: "PINs do not match.", comment: "Set PIN view validation error"))
            return
        }
        guard newPIN.count >= model.minPinLength else {
            presentValidationError(String(localized: "PIN should be at least \(model.minPinLength) characters long."))
            return
        }
        if type == .set {
            model.setPIN(newPIN)
        } else {
            model.changePIN(old: currentPIN, new: newPIN)
        }
    }
}
