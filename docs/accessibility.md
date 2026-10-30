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

## Testing

`AuthenticatorUITests/AccessibilityAuditTests.swift` runs Xcode's accessibility audit
(`performAccessibilityAudit`) on the main screens with the simulated YubiKey and fake Ente server: the account list
and details, the Ente sign in and account list, Configuration, About, the tutorial, the app icons, the QR scanner and
the add account form. It runs with the screenshots (`tools/screenshots.sh`, and the Screenshots workflow in CI), see
[screenshots.md](screenshots.md).

- `testLargestTextSize` launches at the largest accessibility text size (AX5) and fails for clipped text and text
  that doesn't follow the text size. The navigation bar's buttons are left out of the Dynamic Type check: like the
  system's, they keep their size and show the Large Content Viewer instead.

To check by hand, use Accessibility Inspector (Xcode > Open Developer Tool) and the Simulator's Environment Overrides
(text size, appearance, increase contrast, reduce motion, differentiate without color).
