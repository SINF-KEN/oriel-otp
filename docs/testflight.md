# TestFlight

The `TestFlight` workflow (`.github/workflows/testflight.yml`) uploads the iPhone app, with the watch app inside it,
and the Mac app to App Store Connect. It runs after `OrielOTPTests` passes for a push to `main`, so a pull request is
uploaded once it merges. A push that only changes documentation or CI (the same list the tests skip for pull
requests, plus `.github/`) isn't uploaded. The whole push is compared with the commit the previous push to `main`
tested, so a merge commit, a rebase merge or several commits pushed at once count as one change. To upload again, run the workflow by hand from the Actions tab. Once
the `testflight` environment is limited to `main` (see [Secrets](#secrets)), only `main` can be uploaded.

Uploads queue instead of cancelling each other. App Store Connect gives each upload the next free build number
(`manageAppVersionAndBuildNumber`), so `CURRENT_PROJECT_VERSION` doesn't need bumping; the version shown in TestFlight
is still `MARKETING_VERSION`. A build that's still processing isn't counted yet, so a run right after another can be
handed the same number; the upload then waits three minutes and tries again, up to three more times. The archive is
also retried, up to twice, when Apple's API fails while Xcode fetches the provisioning profiles. The archive step sets `ORIEL_COMMIT` to the commit's short SHA, which **About** shows under
the version; builds without it, such as Xcode's Run, don't show one. Once App Store Connect has processed a build,
it's available to internal testers; add it to an external group by hand.

## Signing

The archive is signed for development with the team's Apple Development certificate, installed in a temporary
keychain for the run. At upload, Xcode re-signs it for the App Store with a cloud-managed distribution certificate:
the private key stays with Apple and isn't in the repository's secrets. The API key lets Xcode create and download
the App Store provisioning profiles, including the Mac one the keychain access group needs.

The credentials are on the runner for as short a time as the steps allow:

- The packages are cloned for each upload instead of restored from the cache other workflow runs write, and checked
  against their pinned commits (see [ci.md](ci.md)), before any secret is on the runner.
- The keychain is created after that, and locked as soon as the archive step ends. It's deleted right after the
  upload, before the logs are uploaded.
- The API key is written to `AuthKey.p8` at the start of the archive and upload steps and removed when each ends.
- Every action is pinned to a commit.

The packages are built during the archive, while the keychain is unlocked: that can't be avoided, as Xcode signs
the app at the end of the same build. `security import` only takes the certificate's password as an argument, so it
shows in the process list while the import runs; the runner is a fresh virtual machine used for this job only.

## Secrets

The upload job runs in the `testflight` environment. Set it up once (Settings → Environments → New environment):

1. Name it `testflight`.
2. Under *Deployment branches and tags*, choose *Selected branches and tags* and add `main`, so only main's runs
   (including a manual run of main) can read its secrets.
3. Add the five secrets below as environment secrets, then delete the repository secrets of the same names
   (Settings → Secrets and variables → Actions), so no other workflow or branch can read them.

Until the environment exists, GitHub creates it without protection on the first run, and the job keeps reading the
repository secrets.

| Secret | Value |
| --- | --- |
| `APP_STORE_CONNECT_KEY_ID` | The key's ID, from App Store Connect → Users and Access → Integrations → App Store Connect API. |
| `APP_STORE_CONNECT_ISSUER_ID` | The Issuer ID shown above the list of keys. |
| `APP_STORE_CONNECT_API_KEY` | The contents of the downloaded `AuthKey_<ID>.p8`, including the `BEGIN` and `END` lines. |
| `DEVELOPMENT_CERTIFICATE_P12` | An Apple Development certificate and its private key, exported as `.p12` and base64 encoded: `base64 -i development.p12 \| pbcopy`. |
| `DEVELOPMENT_CERTIFICATE_PASSWORD` | The password chosen when exporting the `.p12`. |

Use an **App Manager** key with *Access to Cloud Managed Distribution Certificate*, not an Admin key: that's all
the workflow needs, and an Admin key can also manage users and every app. Cloud signing isn't available to roles
below App Manager. To switch, create the new key (App Store Connect → Users and Access → Integrations → App Store
Connect API → Team Keys), update the three `APP_STORE_CONNECT_*` secrets, run the workflow by hand once, then
revoke the old key.

To export the certificate, open Keychain Access, select the "Apple Development" certificate for team `XW69FY82W3`
under My Certificates (so the private key comes with it), and choose File → Export Items.

## If an upload fails

Each run uploads the archive and upload logs as `testflight-iOS-logs` and `testflight-macOS-logs`. The usual causes:

- *No signing certificate "Apple Development" found*: the `.p12` is missing its private key, or the password is wrong.
- *Cloud signing permission error*: the API key's role can't use cloud-managed certificates (see above).
- *No profiles for ...*: an App ID or capability changed; the API key can update profiles but can't register a new
  App ID, so add it in the developer portal first.

## App IDs

Each target has its own App ID, registered in the developer portal with these capabilities before the first build
that includes it:

| Target | App ID | Capabilities |
| --- | --- | --- |
| OrielOTPWidgets (iOS) | `io.github.sinf-ken.OrielOTP.Widgets` | App Groups (`group.io.github.sinf-ken.OrielOTP`), Keychain Sharing |
| OrielOTPComplications (watchOS) | `io.github.sinf-ken.OrielOTP.watchkitapp.Complications` | Keychain Sharing |
| OrielOTPWatch (watchOS) | `io.github.sinf-ken.OrielOTP.watchkitapp` (existing) | Keychain Sharing, added for the complication |
