# TestFlight

The `TestFlight` workflow (`.github/workflows/testflight.yml`) uploads the iPhone app, with the watch app inside it,
and the Mac app to App Store Connect. It runs after `OrielOTPTests` passes for a push to `main`, so a pull request is
uploaded once it merges. Commits that only change documentation or CI (the same list the tests skip for pull
requests, plus `.github/`) aren't uploaded. To upload another branch, run the workflow by hand from the Actions tab.

Uploads queue instead of cancelling each other. App Store Connect gives each upload the next free build number
(`manageAppVersionAndBuildNumber`), so `CURRENT_PROJECT_VERSION` doesn't need bumping; the version shown in TestFlight
is still `MARKETING_VERSION`. Once App Store Connect has processed a build, it's available to internal testers; add
it to an external group by hand.

## Signing

The archive is signed for development with the team's Apple Development certificate, installed in a temporary
keychain for the run. At upload, Xcode re-signs it for the App Store with a cloud-managed distribution certificate:
the private key stays with Apple and isn't in the repository's secrets. The API key lets Xcode create and download
the App Store provisioning profiles, including the Mac one the keychain access group needs.

## Secrets

Add these as repository secrets (Settings → Secrets and variables → Actions):

| Secret | Value |
| --- | --- |
| `APP_STORE_CONNECT_KEY_ID` | The key's ID, from App Store Connect → Users and Access → Integrations → App Store Connect API. |
| `APP_STORE_CONNECT_ISSUER_ID` | The Issuer ID shown above the list of keys. |
| `APP_STORE_CONNECT_API_KEY` | The contents of the downloaded `AuthKey_<ID>.p8`, including the `BEGIN` and `END` lines. |
| `DEVELOPMENT_CERTIFICATE_P12` | An Apple Development certificate and its private key, exported as `.p12` and base64 encoded: `base64 -i development.p12 \| pbcopy`. |
| `DEVELOPMENT_CERTIFICATE_PASSWORD` | The password chosen when exporting the `.p12`. |

The API key needs the **Admin** role, or **App Manager** with *Access to Cloud Managed Distribution Certificate*:
cloud signing isn't available to other roles. To export the certificate, open Keychain Access, select the
"Apple Development" certificate for team `XW69FY82W3` under My Certificates (so the private key comes with it), and
choose File → Export Items.

## If an upload fails

Each run uploads the archive and upload logs as `testflight-iOS-logs` and `testflight-macOS-logs`. The usual causes:

- *No signing certificate "Apple Development" found*: the `.p12` is missing its private key, or the password is wrong.
- *Cloud signing permission error*: the API key's role can't use cloud-managed certificates (see above).
- *No profiles for ...*: an App ID or capability changed; the API key can update profiles but can't register a new
  App ID, so add it in the developer portal first.
