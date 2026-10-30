# Accessibility

How Oriel OTP supports the features of App Store Connect's
[Accessibility Nutrition Labels](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/overview-of-accessibility-nutrition-labels/),
and how that is checked. The work is tracked in [issue 57](https://github.com/SINF-KEN/oriel-otp/issues/57).

The common tasks a feature has to work for: add an account (QR code, by hand, from Ente Auth), read and copy a code,
search, pin, rename, delete, sync with Ente Auth, the YubiKey settings, and the app lock.

## VoiceOver

- An account row is one element: issuer, account name and the code read digit by digit ("1 2 3, 4 5 6"), with the
  seconds left and, when Ente Auth accounts are listed, where it's stored as its value. Its actions are the swipe
  actions plus Copy and Move to YubiKey and Rename; on the Mac also Copy, Pin and Delete.
- Toasts (copied, synced, touch the YubiKey) are announced. So are a wrong app lock code and a scanned QR code.
- The app lock screen takes the focus and keeps it from the app behind it. Every sheet with Cancel or Close closes
  with the escape gesture (a two-finger Z).

## Voice Control

Icon buttons answer to their title and to shorter names, e.g. "Tap Plus" or "Tap Add" for Add account, "Tap Scan"
for Scan NFC YubiKey. A row answers to its issuer ("Tap GitHub"). Text fields are named after their row, not their
placeholder.

## Larger Text

All text uses text styles. Icons and images that sit next to text use `@ScaledMetric`, capped where growing further
would crowd out the text. Screens that can get taller than the display scroll (`scrollsWhenTooTall()`), and the
account row puts the code below the name at the accessibility sizes. The app lock's number keys stop growing at a
size where three still fit across the smallest iPhone; held, they show the Large Content Viewer, like the navigation
bar's buttons.

macOS has no text size that apps can follow (System Settings' text size is only for some of Apple's apps), and on the
Mac SwiftUI's text styles and `@ScaledMetric` don't change with `dynamicTypeSize`. So the Mac app has its own text
size, from 100% to 200%: View > Make Text Bigger (⌘+), Make Text Smaller (⌘−) and Actual Size (⌘0), and Settings >
General > Text size. It scales the text styles (`scaledFont(_:)` in place of `font(_:)` with a text style), the
default font of each window (`appTextSize()`), sizes beside text (`@ScaledSize`, which is `@ScaledMetric` on iOS),
and the windows, sheets, sidebar and menu bar extra (`textScaledFrame`), so larger text gets more room instead of
wrapping in a narrow column, up to the size of the screen. A few things keep the system's size, as on iOS: the toolbar,
the search field, menus and alerts.

Two things that don't follow the window's font on the Mac: a list sets the system font on the text in its rows, so the
settings lists are grouped forms there (`SettingsList`); and a button's label keeps the system font unless it sets one,
so forms use `scaledButtonLabels()`. Use these in new Mac views, and `scaledFont(_:)` rather than `font(.body)`.

## Dark Interface

Colors are system colors or asset colors with a dark variant. Text on the accent color (the toast, the Yubico OTP
icon, the Mac menu bar's highlighted row) uses the background color rather than white, as the accent is a light pink
in dark mode. The tutorial and security key drawings have dark versions; the other images are SF Symbols or the
gray YubiKey drawing, which reads on both. The QR scanner is dark in both appearances, over the camera. The watch app
is always dark.

## Differentiate Without Color Alone

Color is never the only sign of a state. Errors and warnings in red or orange have a symbol (the app lock's wait, a
blocked FIDO PIN, an Ente Auth account that can't be added, too many accounts selected). An expired code has the
refresh symbol in place of the countdown, and with Differentiate Without Color it's crossed out too. The watch's ring
turns orange in the last five seconds, and dashed with that setting. Account icons show the account's first letter,
their color only tells them apart. Swipe actions have a symbol and a title.

## Sufficient Contrast

Text has at least 4.5:1 against its background, large text and icons 3:1, with Increase Contrast on (Apple's
criterion is "by default, or when Increase Contrast is on"). By default the system's secondary labels are a little
short of that in places, as in Apple's own apps; everything the app draws itself passes by default too:

- The code is drawn in the full accent color (7.2:1 in light mode, 13.6:1 in dark mode). An expired or not yet
  calculated code is dimmed to 70%, still above 4.5:1, and not at all with Increase Contrast (`colorSchemeContrast`).
- Swipe actions have white labels on Favorite, DeleteAction and CopyAction, which are darker than the system yellow,
  red and blue for at least 4.5:1 in both appearances.
- Every asset color has a high contrast variant, for light and dark mode.

## Reduced Motion

With Reduce Motion on, toasts fade instead of growing and springing, the tutorial's Next and Back swap pages at once,
the app lock's dots don't shake after a wrong code (the haptic, the announcement and the dots emptying still say
so), the QR scanner's checkmark only fades in, the countdown pie steps once a second instead of turning, and rows and
buttons in the YubiKey settings appear without sliding. Fades, which Apple recommends in place of motion, are kept.
Nothing animates on its own or loops; the countdown only follows the time. The watch's ring steps once a second
already.

## Captions and Audio Descriptions

The app has no video or audio: the tutorial is still drawings, and help links open in the browser. These features
don't apply and aren't claimed. Any video added later needs captions and an audio description, or a text alternative,
before it's released (see [app-store.md](app-store.md)).

## AI agents and UI tests

Agents and UI tests drive the app through the same accessibility tree as VoiceOver, so the labels, values, actions
and headers above serve them too. Key elements also have a stable `accessibilityIdentifier`, which doesn't change with
the language or the visible text. The UI tests find elements by these.

The scheme is `<screen>.<element>`, in lowercase words joined by hyphens, with the item's id after a further dot
where there are many of a kind:

| Screen | Identifiers |
| --- | --- |
| Account list | `accounts.add-account`, `accounts.scan-nfc`, `accounts.refresh` (Mac), `accounts.sync-from-ente` (the button in the empty list) |
| A row | `account-row.<account id>`: the YubiKey's credential id, e.g. `account-row.GitHub:alice@example.com` or `account-row.60/Bank:alice`, or `ente/<item id>` for Ente Auth |
| Account details | `account-details.code`, `account-details.copy`, `account-details.calculate`, `account-details.pin`, `account-details.rename`, `account-details.delete` |
| Add account | `add-account.issuer`, `add-account.account-name`, `add-account.secret`, `add-account.save`, `add-account.enter-manually` |
| Ente sync | `ente.email`, `ente.password`, `ente.sign-in`, `ente.server`, `ente.stay-signed-in`, `ente.add` |
| App lock | `app-lock.unlock`, `app-lock.key.<digit>`, `app-lock.delete`, `app-lock.password` |
| About | `about.tutorial`, `about.version-history`, `about.app-icon`, `tutorial.next`, `tutorial.back` |

The search field is the system's (`app.searchFields.firstMatch`), and the account list's menu is the system's More
button (`OverflowBarButtonItem`). Its items (Sync from Ente Auth, Configuration, About) don't keep identifiers on iOS,
so they're found by their title. Name new identifiers the same way and add them here.

App Intents cover the tasks that make sense from outside the app: Scan NFC YubiKey and Add Account on iOS (Siri,
Shortcuts, Spotlight, Apple Intelligence), Add Account and Copy Code on the Mac, with a parameter for the account.

## Testing

`AuthenticatorUITests/AccessibilityAuditTests.swift` runs Xcode's accessibility audit
(`performAccessibilityAudit`) on the main screens with the simulated YubiKey and fake Ente server: the account list
and details, the Ente sign in and account list, Configuration, About, the tutorial, the app icons, the QR scanner and
the add account form. It runs with the screenshots (`tools/screenshots.sh`, and the Screenshots workflow in CI), see
[screenshots.md](screenshots.md).

- `testLightAppearance` fails for text or icons without enough contrast in light mode. Text that nearly passes, like
  the system's secondary labels in places, is left to the Increase Contrast check. Disabled controls are left out, as
  WCAG does, and so is what the keyboard covers.
- After the screenshots, `tools/screenshots.sh` switches the simulator to dark mode with `simctl` and runs
  `testDarkAppearance`, the same check in dark mode, then turns on Increase Contrast and runs `testIncreasedContrast`
  in light and dark mode, where nothing has to nearly pass. The tests skip themselves in a normal run.
- `testLargestTextSize` launches at the largest accessibility text size (AX5) and fails for clipped text and text
  that doesn't follow the text size. The navigation bar's buttons are left out of the Dynamic Type check: like the
  system's, they keep their size and show the Large Content Viewer instead.

To check by hand, use Accessibility Inspector (Xcode > Open Developer Tool) and the Simulator's Environment Overrides
(text size, appearance, increase contrast, reduce motion, differentiate without color).
