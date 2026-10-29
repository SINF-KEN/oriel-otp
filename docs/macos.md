# The Mac version

The Mac version is being built in steps, following the checklist in
[issue #18](https://github.com/SINF-KEN/oriel-otp/issues/18).

## Approach: a native macOS destination

The `Authenticator` target builds for macOS as well as iOS (`SUPPORTED_PLATFORMS = "iphoneos iphonesimulator
macosx"`), with macOS 14 as the minimum. It's the same SwiftUI app, compiled against AppKit instead of UIKit.

The alternatives were Mac Catalyst and running the iPad app on Apple silicon ("Designed for iPad"). The native
destination was chosen because:

- YubiKit 1.4.0 supports macOS natively. It talks to a YubiKey as a USB smart card through CryptoTokenKit, which is
  how the Mac itself sees the key. Under Catalyst `os(iOS)` is true, so YubiKit and the app would compile their NFC
  and Lightning code, which can't work on a Mac.
- The app is already SwiftUI, so most views work on the Mac unchanged. What's left are Mac conventions (menu bar
  commands, a Settings window, keyboard use) that SwiftUI supports directly on macOS, and only partly under Catalyst.
- `MenuBarExtra` and the `Settings` scene aren't available to Catalyst or iPad apps.
- "Designed for iPad" runs the iPad app unchanged, so nothing can be adapted for the Mac.

macOS 14 is the minimum for the newer SwiftUI APIs (`@Observable`, which the app uses throughout, and the Settings
and menu bar scenes).

## How the code is shared

- iOS-only code is behind `#if os(iOS)`. On the Mac there is no NFC, Lightning, camera QR scanner, Home Screen
  quick actions, alternate app icons or smart card extension.
- `Authenticator/UI/Helpers/Platform.swift` holds what both platforms do differently: opening links, copying codes,
  haptics, and no-op versions of the iOS keyboard and navigation bar modifiers so shared views don't need `#if`
  around each of them.
- On the Mac, a copied code is marked as concealed (`org.nspasteboard.ConcealedType`) so clipboard managers skip it,
  and it is removed from the pasteboard after a minute unless something else was copied.
- Mac-only code is in `Authenticator/Mac`, a folder Xcode adds to the target by itself, with each file inside
  `#if os(macOS)`.
- `ConnectionManager` only has wired (USB) connections on the Mac. The NFC methods are kept, and do nothing or throw
  `unsupported`, so callers don't change.
- The keychain uses the data protection keychain on the Mac (`kSecUseDataProtectionKeychain`), the same kind as on
  iOS, so the access control flags for Touch ID work and the login keychain isn't involved.

## The Mac interface

Following the [HIG for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos):

- **One window** (`Window`, not `WindowGroup`): the accounts all come from the one plugged-in YubiKey, so a second
  window would only show the same list. It opens at 900 × 600 points with a minimum of 640 × 420, and macOS
  remembers its size and position. The account list is the sidebar of the split view and the details are on the
  right. Closing the window keeps the app running for the menu bar; the Dock icon or the menu bar opens it again.
- **Menu bar commands** (`Authenticator/Mac/MainCommands.swift`): File > Add Account… (⌘N) and Sync from Ente
  Auth… (⇧⌘E); Edit > Copy (⌘C copies the selected account's code, or text while editing it) and Search Accounts
  (⌘F, macOS 15 and later); an Account menu with Copy Code, Pin (⇧⌘P), Rename…, Delete… (⌘⌫) and Refresh (⌘R);
  About in the app menu; help, the tutorial, support and the privacy policy in the Help menu; and File > Import From
  Device for Continuity Camera. The main view publishes only a small `Equatable` state for the menus, and the
  commands reach it through `MainWindowCommands`; publishing closures made SwiftUI rebuild the menus constantly.
- **Keyboard**: the list can be used with the arrow keys, Return copies the code, Delete deletes, Escape and Return
  cancel and confirm sheets. Several accounts can be selected to pin or delete them together.
- **Settings** (⌘,): General (menu bar, menu bar only, open at login) and YubiKey, the configuration screen that is a
  sheet on iOS.
- **Toolbar**: Refresh, Add and Sync from Ente Auth, with help tags. There is no pull to refresh; the YubiKey is
  read when it's plugged in. Copy and pin also appear on a row when the pointer is over it, in place of swipe actions.
- **Density**: smaller row icons and text, and a larger code, sized for the Mac's 13 pt body text.
- **Toasts** are a small banner at the bottom of the window.
- **Touch**: when a code needs a touch and the app isn't in front, e.g. when copying from the menu bar or Shortcuts,
  a notification asks for it (`TouchPrompt`), and is removed once the key was touched.

## Mac features

- **Menu bar extra** (`MenuBarAccountsView`): the pinned accounts, or all of them if none are pinned; a click copies
  the code. It connects to the YubiKey itself while the main window is closed. Settings can hide it, or show the app
  only in the menu bar (no Dock icon, `NSApplication.ActivationPolicy.accessory`).
- **QR codes without a camera** (`QRCodeReader`): Scan QR Code on Screen captures each display with
  ScreenCaptureKit, leaving out the app's own windows, which needs the Screen Recording permission; Paste QR Code or
  Link reads an image or an `otpauth://` link from the pasteboard; a picture can be dropped on the sheet; and File >
  Import From Device takes one with an iPhone or iPad. QR codes are found with Core Image. Entering the details by
  hand still works.
- **Shortcuts and Spotlight** (`MacIntents.swift`): Copy Code, with the account picked from the plugged-in YubiKey,
  and Add Account. The Dock menu also has Add Account. Both open `orielotp://add-account`, which brings back the
  window when it was closed.
- **Touch ID** protects a saved YubiKey password and the saved Ente session, as Face ID does on iOS.
- **Open at login** uses `SMAppService`.

## Signing and entitlements

The Mac build uses `Authenticator/Authenticator-macOS.entitlements` and `Authenticator/Info-macOS.plist`, selected
with `[sdk=macosx*]` build settings:

| Entitlement | Why |
| --- | --- |
| `com.apple.security.app-sandbox` | Required for the Mac App Store |
| `com.apple.security.smartcard` | Talks to the YubiKey's OATH application over CCID |
| `com.apple.security.network.client` | Ente Auth |
| `keychain-access-groups` | The data protection keychain, for saved passwords and the Ente session |

The app group isn't used on the Mac, since it only shares data with the iOS smart card extension, which isn't part of
the Mac build. The NFC entitlement and the iOS-only `Info.plist` keys aren't there either. Add
`com.apple.security.device.usb` if the app starts using YubiKit's HID connections (OTP or FIDO over USB).

`keychain-access-groups` needs a provisioning profile, so set your team in Xcode to run the Mac app with the keychain.
CI signs the Mac build ad hoc without it, and the keychain tests skip themselves when it's missing (see
[ci.md](ci.md)).

## Testing

- The unit tests run on the Mac too, in CI (see [ci.md](ci.md)).
- `AuthenticatorUITests/MacScreenshotTests.swift` takes the Mac screenshots and checks the other windows, the
  Settings tabs and that the Dock menu's Add Account opens a closed window (see [screenshots.md](screenshots.md)).
- Debug builds use the simulated YubiKey and the fake Ente server when launched with `-SimulatedYubiKey YES`, with a
  Debug menu to plug and unplug it. Without that argument they use a real YubiKey.
- A real YubiKey, Touch ID, the screen recording prompt, Continuity Camera and the notification can only be checked
  by hand.

## App icon

The Mac build uses the same `Authenticator/AppIcon.icon` and `AppIcon-Dark.icon` as iOS; Xcode compiles them into
`AppIcon.icns` and `Assets.car`. To check how they look on the Mac, render them with Icon Composer's `ictool`:

```sh
ICTOOL="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
for rendition in Default Dark ClearLight; do
  "$ICTOOL" Authenticator/AppIcon.icon --export-image --output-file "/tmp/AppIcon-$rendition.png" \
    --platform macOS --rendition "$rendition" --width 512 --height 512 --scale 1
done
```

Use `--width 16 --height 16 --scale 2` for the smallest Finder size. Both icons were checked this way in light, dark
and clear, down to 16 pt.

## Not in the Mac version

- The smart card extension and its screens: macOS reads the YubiKey's PIV certificates with its own driver.
- FIDO PIN and reset: they need NFC or Lightning on iOS, and YubiKit's FIDO over USB uses HID, which the Mac app
  doesn't use yet.
- NFC settings, NFC scanning and the Yubico OTP NFC link.
- Alternate app icons.
