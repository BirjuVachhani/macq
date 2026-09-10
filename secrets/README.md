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
| `config.mk` | always | Your signing identity, notary credentials and R2 token. Read by the root `Makefile`. |
| `DeveloperID_Application.p12` | CI, or a machine without the identity in its login keychain | Export from Keychain Access: right-click the "Developer ID Application" identity, Export, choose .p12, set a password. Set `CERT_P12` and `CERT_P12_PASSWORD`, then run `make keychain-import`. |
| `AuthKey_XXXXXXXXXX.p8` | notarizing with an App Store Connect API key | Downloadable exactly once from App Store Connect. Set `ASC_API_KEY_FILE`, `ASC_API_KEY_ID`, `ASC_API_ISSUER_ID`. |
| `MacQ_DeveloperID.provisionprofile` | only if the app gains provisioned entitlements | Developer ID apps do not need a profile for plain distribution. Set `PROVISIONING_PROFILE` and it is embedded before signing. |
| `MacQ.entitlements` | only if the app gains entitlements | MacQ currently needs none. Set `ENTITLEMENTS` if that changes. |
| `sparkle_ed25519_private.key` | `make appcast` / `make release` | The EdDSA key that signs in-app updates. No passphrase: the file is the secret. Also in the login keychain under the `macq` account. |

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

That leaves `config.mk` free of Apple passwords and keys.

## Publishing credentials

`make release` uploads the DMG, its checksum and the Sparkle appcast to a
Cloudflare R2 bucket over R2's S3-compatible API. That needs an R2 API token of
type "Object Read & Write" (Cloudflare dashboard, R2, API, Manage API tokens),
not a global API key, and its access key ID and secret go in `config.mk` as
`R2_ACCESS_KEY_ID` and `R2_SECRET_ACCESS_KEY`. They cannot live in the keychain
the way the notary credentials can, so this is the one place `config.mk` does
hold a secret. The upload passes them to `curl` through the environment and a
config file on stdin, never on a command line, so they do not show up in `ps`.

Nothing here needs the R2 settings: `make dmg` produces the same notarized DMG
without them, and refuses nothing.

## The Sparkle signing key

MacQ's in-app updates are gated on an EdDSA key pair. The public half is checked
in at `SUPublicEDKey` in `app/MacQ/Info.plist`. The private half is here as
`sparkle_ed25519_private.key`, and also in your login keychain under the `macq`
account; `make appcast` prefers the file and falls back to the keychain, so a
release still builds on a machine whose keychain is empty.

The key is kept under a named account rather than Sparkle's default because this
machine's default account already holds a different key. `sign_update` with no
account would sign MacQ with that one instead, and every installed copy would
refuse the update. Nothing reports that at build time, which is why `make doctor`
compares the key actually in use against `SUPublicEDKey` and says so loudly when
they are not a pair.

Unlike the `.p12`, this key has no passphrase. The file itself is the secret, so
it is mode 600 and `.gitignore` already covers it.

The app installs nothing that key did not sign, which also means that losing it
ends in-app updates permanently: every existing install would have to be
replaced by hand. Keep a backup somewhere offline:

```sh
./build/sparkle-tools/bin/generate_keys --account macq -x backup.key
```

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

The workflow runs `make dmg`, not `make release`: it attaches the DMG to a
GitHub release and stops there. Publishing to R2 and refreshing the Sparkle
appcast is done from a maintainer's machine, so neither the R2 token nor the
Sparkle signing key is a repository secret.

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
