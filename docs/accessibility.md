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

## Dark Interface

Colors are system colors or asset colors with a dark variant. Text on the accent color (the toast, the Yubico OTP
icon, the Mac menu bar's highlighted row) uses the background color rather than white, as the accent is a light pink
in dark mode. The tutorial and security key drawings have dark versions; the other images are SF Symbols or the
gray YubiKey drawing, which reads on both. The QR scanner is dark in both appearances, over the camera. The watch app
is always dark.

## Sufficient Contrast

Text has at least 4.5:1 against its background, large text and icons 3:1, with Increase Contrast on (Apple's
criterion is "by default, or when Increase Contrast is on"). By default the system's secondary labels are a little
short of that in places, as in Apple's own apps; everything the app draws itself passes by default too:

- The code is drawn in the full accent color (7.2:1 in light mode, 13.6:1 in dark mode). An expired or not yet
  calculated code is dimmed to 70%, still above 4.5:1, and not at all with Increase Contrast (`colorSchemeContrast`).
- Swipe actions have white labels on Favorite, DeleteAction and CopyAction, which are darker than the system yellow,
  red and blue for at least 4.5:1 in both appearances.
- Every asset color has a high contrast variant, for light and dark mode.

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
