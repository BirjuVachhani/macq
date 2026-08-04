# secrets/

Everything the release pipeline needs that must not be committed. The
[.gitignore](.gitignore) here ignores the whole directory except itself, this
README and `config.mk.example`, so anything you drop in is untracked by default.

## Setup

```sh
cp secrets/config.mk.example secrets/config.mk
$EDITOR secrets/config.mk
make doctor
```

`make doctor` reports the toolchain and every setting it could not resolve.

## What goes here

| File | Needed for | Notes |
| --- | --- | --- |
| `config.mk` | always | Your signing identity and notary credentials. Read by the root `Makefile`. |
| `DeveloperID_Application.p12` | CI, or a machine without the identity in its login keychain | Export from Keychain Access: right-click the "Developer ID Application" identity, Export, choose .p12, set a password. Set `CERT_P12` and `CERT_P12_PASSWORD`, then run `make keychain-import`. |
| `AuthKey_XXXXXXXXXX.p8` | notarizing with an App Store Connect API key | Downloadable exactly once from App Store Connect. Set `ASC_API_KEY_FILE`, `ASC_API_KEY_ID`, `ASC_API_ISSUER_ID`. |
| `MacQ_DeveloperID.provisionprofile` | only if the app gains provisioned entitlements | Developer ID apps do not need a profile for plain distribution. Set `PROVISIONING_PROFILE` and it is embedded before signing. |
| `MacQ.entitlements` | only if the app gains entitlements | MacQ currently needs none. Set `ENTITLEMENTS` if that changes. |

## Credentials on your own machine

The lowest-exposure setup is to keep nothing sensitive in this directory at all:

1. Keep the Developer ID certificate in your login keychain (no `.p12` on disk).
2. Store the notary credentials in the keychain once:

   ```sh
   xcrun notarytool store-credentials "MacQ-notary" \
     --apple-id you@example.com --team-id ABCDE12345 --password xxxx-xxxx-xxxx-xxxx
   ```

3. In `config.mk`, set only `SIGN_IDENTITY`, `TEAM_ID` and
   `NOTARY_KEYCHAIN_PROFILE`.

That leaves `config.mk` free of passwords and keys.

## Credentials in CI

The [release workflow](../.github/workflows/release.yml) builds the signed and
notarized DMG on a GitHub-hosted macOS runner and attaches it to a release. It
needs these repository secrets (Settings > Secrets and variables > Actions):

| Secret | Value |
| --- | --- |
| `MACOS_CERT_P12_BASE64` | `base64 -i secrets/DeveloperID_Application.p12 \| pbcopy` |
| `MACOS_CERT_P12_PASSWORD` | The password set when exporting that `.p12` |
| `MACOS_SIGN_IDENTITY` | Full identity name, exactly as `make identities` prints it |
| `APPLE_TEAM_ID` | Your 10-character Team ID |

Plus notarization credentials, either the App Store Connect API key (preferred,
no password anywhere):

| Secret | Value |
| --- | --- |
| `ASC_API_KEY_P8_BASE64` | `base64 -i secrets/AuthKey_XXXXXXXXXX.p8 \| pbcopy` |
| `ASC_API_KEY_ID` | The key ID, e.g. `ABCDE12345` |
| `ASC_API_ISSUER_ID` | The issuer UUID from App Store Connect |

or the Apple ID fallback: `APPLE_ID` and `APPLE_APP_PASSWORD`.

The workflow passes all of these to `make` through the environment, so no
`config.mk` is written on the runner and only the decoded `.p12`/`.p8` briefly
touch this directory (deleted again in the job's last step). Because the
credentials are not in `config.mk`, `make doctor` on the runner reports that file
as `MISSING` while still resolving every setting; that one line is expected.

The keychain handling is the same as anywhere else: `keychain-import` creates a
temporary keychain (`macq-build.keychain-db`) rather than touching the login
keychain, and `keychain-remove` deletes it again.

CI builds the DMG with `hdiutil` (`DMG_TOOL=hdiutil`) rather than `create-dmg`,
which needs Finder over AppleScript and so cannot lay out the window on a
headless runner. The result is a valid but unstyled DMG: the app plus an
`/Applications` symlink.
