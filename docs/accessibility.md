# Accessibility

How Oriel OTP supports the features of App Store Connect's
[Accessibility Nutrition Labels](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/overview-of-accessibility-nutrition-labels/),
and how that is checked. The work is tracked in [issue 57](https://github.com/SINF-KEN/oriel-otp/issues/57).

The common tasks a feature has to work for: add an account (QR code, by hand, from Ente Auth), read and copy a code,
search, pin, rename, delete, sync with Ente Auth, the YubiKey settings, and the app lock.

## VoiceOver

- An account row is one element: issuer, account name and the code read digit by digit ("1 2 3, 4 5 6"), with the
  seconds left and, when Ente Auth accounts are listed, where it's stored as its value. Its actions are, in order,
  Copy, Pin, Move to YubiKey, Rename, Tags and Delete, on iOS and the Mac. With VoiceOver on, iOS leaves out the swipe
  actions and gives the row these instead, so Copy is always the first action.
- The code in a row is a button that copies it, but with VoiceOver the row is one element, so VoiceOver copies with
  the row's Copy action instead. On iOS the row's hint says so ("Swipe up or down to copy the code"). After copying,
  the toast is announced, and the row shows a checkmark for a moment.
- Toasts (copied, synced, touch the YubiKey) are announced. So are a wrong app lock code and a scanned QR code.
- On the Mac, rows in the main window's single column are buttons too, with an action that opens the account, and the
  list takes the keyboard focus at launch and after going back.
- The app lock screen takes the focus and keeps it from the app behind it. Every sheet with Cancel or Close closes
  with the escape gesture (a two-finger Z).

## Voice Control

Icon buttons answer to their title and to shorter names, e.g. "Tap Plus" or "Tap Add" for Add account, "Tap Scan"
for Scan NFC YubiKey. A row answers to its issuer ("Tap GitHub"). Text fields are named after their row, not their
placeholder.

On iOS without VoiceOver, the code in a row is a button of its own, named "Copy code for GitHub", so "Copy GitHub" or
"Copy code GitHub" copies it without opening the account, and "Show numbers" and "Show grid" reach it. Switch Control
and Full Keyboard Access move to it as well. "Tap GitHub" still opens the account. On the Mac a row is a button that
can't hold another, so it stays one element; the row's Copy button appears when the pointer is over it.

## Larger Text

All text uses text styles. Icons and images that sit next to text use `@ScaledMetric`, capped where growing further
would crowd out the text. Screens that can get taller than the display scroll (`scrollsWhenTooTall()`), and on the
iPhone and iPad the account row puts the issuer and name on one line with the code in large type below it whenever
the name would get narrower than about 150 points beside the code: from one size up on most iPhones, and at every
size on an iPhone mini. In an iPad's sidebar that's about 110 points, so that a code of 8 digits fits too. The app lock's number keys stop growing at a
size where three still fit across the smallest iPhone; held, they show the Large Content Viewer, like the navigation
bar's buttons.

macOS has no text size that apps can follow (System Settings' text size is only for some of Apple's apps), and on the
Mac SwiftUI's text styles and `@ScaledMetric` don't change with `dynamicTypeSize`. So the Mac app has its own text
size, from 100% to 200%: View > Make Text Bigger (⌘+), Make Text Smaller (⌘−) and Actual Size (⌘0), and Settings >
General > Text size. It scales the text styles (`scaledFont(_:)` in place of `font(_:)` with a text style), the
default font of each window (`appTextSize()`), sizes beside text (`@ScaledSize`, which is `@ScaledMetric` on iOS),
and the windows, sheets, sidebar and menu bar extra (`textScaledFrame`), so larger text gets more room instead of
wrapping in a narrow column, up to the size of the screen. The main window keeps its size, and its two columns become
one when they no longer fit at the larger text. A few things keep the system's size, as on iOS: the toolbar,
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
blocked FIDO PIN, an Ente Auth account that can't be added, too many accounts selected). An expired code is replaced by
asterisks, with the refresh symbol in place of the countdown. The watch's ring
turns orange in the last five seconds, and dashed with that setting. Account icons show the account's first letter,
their color only tells them apart. Swipe actions have a symbol and a title.

## Sufficient Contrast

Text has at least 4.5:1 against its background, large text and icons 3:1, with Increase Contrast on (Apple's
criterion is "by default, or when Increase Contrast is on"). By default the system's secondary labels are a little
short of that in places, as in Apple's own apps; everything the app draws itself passes by default too:

- The code is drawn in the full accent color (7.2:1 in light mode, 13.6:1 in dark mode). The placeholder for an
  expired or not yet calculated code is dimmed to 70%, still above 4.5:1, and not at all with Increase Contrast (`colorSchemeContrast`).
- Swipe actions have white labels on Favorite, DeleteAction and CopyAction, which are darker than the system yellow,
  red and blue for at least 4.5:1 in both appearances.
- The app lock's buttons have white labels on UnlockButton, the accent in light mode and a darker pink in dark mode,
  for at least 4.5:1. The accent itself stays light in dark mode, as the codes are drawn in it.
- Every asset color has a high contrast variant, for light and dark mode.

A selected row is highlighted in the accent color, so everything on it changes with it: on iOS the code and the
account name are in the background color, like other text on the accent color, and white on the Mac, whatever the code's
button would otherwise be drawn in. The letter on the account icon keeps its color, as the icon doesn't change.

With Button Shapes on, the code below the name gets the outline the code beside the name always has.

## Reduced Transparency

The app has no transparency of its own to reduce. The only material is the system's, behind the Mac's toast, and the
system's materials become opaque with this setting.

## Reduced Motion

With Reduce Motion on, toasts fade instead of growing and springing, the tutorial's Next and Back swap pages at once,
the app lock's dots don't shake after a wrong code (the haptic, the announcement and the dots emptying still say
so), the QR scanner's checkmark only fades in, the countdown pie steps once a second instead of turning, and rows and
buttons in the YubiKey settings appear without sliding. Fades, which Apple recommends in place of motion, are kept.
Nothing animates on its own or loops; the countdown only follows the time. The watch's ring steps once a second
already.

## Keyboard and pointer

On the Mac every action is in the menu bar, see [macos.md](macos.md). In the main window's single column the arrow keys
move through the list, → opens the selected account, and Back or Escape returns.

On an iPad with a hardware keyboard, ⌘N adds an account, ⌘F goes to the search field, and in the details ⌘C copies the
code and ⌘R calculates a new one. A pointer highlights the codes, which can be clicked to copy them.

## Right to left

The app isn't translated into Arabic or Hebrew yet, but account names often are in those scripts, and the layout is
ready for a translation:

- Names keep their own direction. A name on its own is shown as it is, except an email address, which stays left to
  right (`leftToRightIfAddress`). A name or address inside a sentence or next to another name is isolated
  (`isolated`), and the issuer · name line starts with a mark in the app's direction, so the issuer comes first in
  English and in Arabic, whatever script the names are in.
- Search takes any keyboard, and ignores case, accents and vowel marks (`localizedStandardContains`).
- Codes and PINs that are compared byte for byte (the app lock, the Ente verification code, the PIV PIN) turn
  Arabic-Indic and other digits into ASCII ones (`asciiDigits`), and the Ente code field uses the ASCII number pad.
- The layout mirrors, with these exceptions, like the system's: the app lock's number pad stays 1 2 3, and the
  countdown pie and the watch's ring turn clockwise. Directional symbols use the `forward` and `backward` names,
  which mirror. The Ente sync drawing mirrors; the others show objects or digits and don't.
- Sentences are whole strings, never pieced together, and counts have plural variations, so translators can word
  and order them as Arabic's six plural forms need. VoiceOver labels join their parts with a translatable separator
  (`String.accessibilitySeparator`, "،" in Arabic).

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
| Account list | `accounts.add-account`, `accounts.empty-add-account`, `accounts.scan-nfc`, `accounts.refresh` (Mac), `accounts.sync-from-ente` (the button in the empty list), `accounts.search`, `accounts.tag-filter`, `accounts.clock-warning`, `accounts.about`, `accounts.configuration` |
| A row | `account-row.<account id>`: the YubiKey's credential id, e.g. `account-row.GitHub:alice@example.com` or `account-row.60/Bank:alice`, or `ente/<item id>` for Ente Auth; its code, on iOS without VoiceOver: `account-row.<account id>.copy` |
| QR code | `account-qr-code.image`, `account-qr-code.done` |
| Account details | `account-details.code`, `account-details.next-code`, `account-details.copy`, `account-details.qr-code`, `account-details.calculate`, `account-details.pin`, `account-details.rename`, `account-details.delete`, `account-details.tags`, `account-details.tag-list`, `account-details.autofill-websites`, `account-details.toolbar-autofill-websites` |
| Tags | `tags.new-tag` |
| Add account | `add-account.issuer`, `add-account.account-name`, `add-account.secret`, `add-account.save`, `add-account.enter-manually` |
| Ente sync | `ente.email`, `ente.password`, `ente.sign-in`, `ente.server`, `ente.server-choice`, `ente.stay-signed-in`, `ente.add`, `ente.create-account`, `ente.migrate`, `ente.delete-account` |
| Ente sign up | `ente.sign-up.email`, `ente.sign-up.continue`, `ente.sign-up.code`, `ente.sign-up.verify`, `ente.sign-up.password`, `ente.sign-up.confirm`, `ente.sign-up.create`, `ente.sign-up.recovery-key`, `ente.sign-up.saved`, `ente.sign-up.done` |
| Moving to another server | `ente.migrate.email`, `ente.migrate.password`, `ente.migrate.sign-in`, `ente.migrate.continue`, `ente.migrate.confirm`, `ente.migrate.move`, `ente.migrate.done` |
| Deleting the Ente account | `ente.delete-account.email`, `ente.delete-account.password`, `ente.delete-account.code`, `ente.delete-account.confirm`, `ente.delete-account.delete`, `ente.delete-account.done` |
| Settings | `configuration.oath-storage`, `settings.hide-codes`, `settings.spotlight` |
| App lock | `app-lock.unlock`, `app-lock.key.<digit>`, `app-lock.delete`, `app-lock.password` |
| About | `about.commit` (release builds only), `about.tutorial`, `about.version-history`, `about.app-icon`, `tutorial.next`, `tutorial.back` |

The search field is the system's (`app.searchFields.firstMatch`), and the account list's menu is the system's More
button (`OverflowBarButtonItem`, `TopOverflowBarButtonItem` from iOS 27.2). Its items (Sync from Ente Auth, Configuration, About) don't keep identifiers on iOS,
so they're found by their title. Name new identifiers the same way and add them here.

App Intents cover the tasks that make sense from outside the app (Siri, Shortcuts, Spotlight, Apple Intelligence):
Copy Code and Open Account on iOS and the Mac (`Accounts/AccountIntents.swift`), with a parameter for the account, for
Ente Auth accounts and those on this device; Scan NFC YubiKey on iOS; and Add Account on both.

## Testing

`AuthenticatorUITests/AccessibilityAuditTests.swift` runs Xcode's accessibility audit
(`performAccessibilityAudit`) on the main screens with the simulated YubiKey and fake Ente server: the account list
and details, the Ente sign in and account list, Configuration, About, the tutorial, the app icons, the QR scanner and
the add account form. It runs with `tools/screenshots.sh audits`, and the Accessibility workflow in CI, which is run by
hand. See [screenshots.md](screenshots.md).

- `testLightAppearance` fails for text or icons without enough contrast in light mode. Text that nearly passes, like
  the system's secondary labels in places, is left to the Increase Contrast check. Disabled controls are left out, as
  WCAG does, and so is what the keyboard covers.
- `tools/screenshots.sh audits` then switches the simulator to dark mode with `simctl` and runs `testDarkAppearance`,
  the same check in dark mode, then turns on Increase Contrast and runs `testIncreasedContrast` in light and dark
  mode, where nothing has to nearly pass. The tests skip themselves in a normal run.
- `testRightToLeft` launches with the right-to-left pseudolanguage (`-AppleTextDirection YES
  -NSForceRightToLeftWritingDirection YES`), English text in a mirrored layout, at the largest text size, and fails for clipped text.
- `testLargestTextSize` launches at the largest accessibility text size (AX5) and fails for clipped text and text
  that doesn't follow the text size. The navigation bar's buttons are left out of the Dynamic Type check: like the
  system's, they keep their size and show the Large Content Viewer instead.

The Dynamic Type audit steps the app through the text sizes, and rows are recycled as they grow and shrink. Right after
scrolling a list it reports clipped text and text that doesn't scale with no element, on both an iPhone and an iPad, for
rows that are fine; a second audit reports nothing. So the tests audit a screen before scrolling it.

The same audits run on an iPad, whose details are beside the list. Its sidebar is glass, and in dark mode the audit fails
some of its text level with what's in the details, which an iPhone doesn't. The test then measures the text in a
screenshot, and it only passes if the lightest and darkest pixels have the contrast it needs. On the Mac, `testAccessibilityAudit` in
`AuthenticatorUITests/MacScreenshotTests.swift` audits each layout of the main window at 100% and 200%.

`AuthenticatorUITests/TapToCopyTests.swift` taps the code in a row, beside the name and below it at a larger text size,
and checks that it's copied without opening the account; also 24 points above the code, for the 44 point target. Tapping
the name opens the account without copying. Without VoiceOver the code is a button of its own, named after the account
for Voice Control, which copies without opening the account.

To check by hand, use Accessibility Inspector (Xcode > Open Developer Tool) and the Simulator's Environment Overrides
(text size, appearance, increase contrast, reduce motion, differentiate without color). For right to left, set the
scheme's App Language to Right-to-Left Pseudolanguage.
