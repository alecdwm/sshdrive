# Cutting a release

A release is a `v*` tag. Pushing it runs `.github/workflows/release.yml`, which builds, signs,
notarizes and staples the app, attaches `SSH-Drive-<version>.dmg` to a GitHub release, and
pushes the updated cask to `alecdwm/homebrew-tap`. The version comes from the `VERSION` file;
the tag only triggers the run and must be exactly `v$(cat VERSION)`.

## Before you start

- The seven [repository secrets](#the-secrets) are set.
- The provisioning profile was issued for the signing certificate
  ([check it](#the-profile-must-name-the-signing-certificate)). A mismatch fails the build.
- A real Mac with Homebrew is at hand for the checks after the release. No runner or VM can
  stand in for it.

## Steps

### 1. Stamp, tag and push

`scripts/set-version.sh` writes `VERSION`, `project.yml`, the helper crate, `Cargo.lock`,
`Version.swift` and the cask:

```sh
scripts/set-version.sh 0.2.0
git commit -am "Bump to 0.2.0"
git tag v0.2.0
git push origin main v0.2.0
```

### 2. Wait for the workflow

When `release` is green, the GitHub release carries `SSH-Drive-<version>.dmg` and its
`.sha256`, and `alecdwm/homebrew-tap` has a commit `sshdrive <version>`.

### 3. Install through the cask on a real Mac

```sh
brew install --cask sshdrive
sshdrive doctor
xattr -p com.apple.quarantine "/Applications/SSH Drive.app"   # must print nothing
```

`quarantine` and `extension registered` must both be `ok`, and `file provider domains` must
not say *The application cannot be used right now*. LaunchServices registers no plugin of a
bundle still carrying `com.apple.quarantine` that no person has launched, which is why the
cask's `postflight` assesses the app with `spctl` and then strips the attribute.

### 4. Upgrade over an existing install

On a machine that already has SSH Drive, run `brew upgrade --cask sshdrive` and check that
the sidebar entries, the cached files and any pending upload are still there.

To test the upgrade path against a build that is not in a cask yet,
`scripts/release.sh install` (or `RELEASE_INSTALL=1 scripts/release.sh`) runs the same stop,
replace, `unregister` and `open -g` sequence on the build Mac.

### 5. Lint the cask

`brew style` and `brew audit --new --cask alecdwm/tap/sshdrive` need a Homebrew install,
which neither the Linux box nor the build VM has. The `tap` job only runs `ruby -c` on the
rendered cask, which is not the same check.

## What the workflow does

| Job | Where | What |
|---|---|---|
| `check` | `swift:6.3-noble` on ubuntu | the tag-and-`VERSION` check, `scripts/set-version.sh --check`, `swift test` in `Packages/SSHDriveCore` |
| `helper` | `.github/workflows/helper.yml` | `cargo test`, `cargo clippy`, then the five helper binaries and `manifest.json` as the `helper-bundle` artifact |
| `release` | `macos-26` | `scripts/release.sh` with the secrets below: xcodegen, `xcodebuild -configuration Release`, embed the helper, Developer ID sign with the hardened runtime, DMG, notarize, staple, `spctl --assess`. Uploads the DMG and creates the GitHub release |
| `tap` | ubuntu | renders `packaging/cask/sshdrive.rb` with the new version and the DMG's sha256 and pushes it to `alecdwm/homebrew-tap` as `Casks/sshdrive.rb`, commit message `sshdrive <version>` |

`release` needs both `check` and `helper`, and `helper` builds nothing until its own
`cargo test` and `cargo clippy` pass, so nothing is published before the tests are green.

`release` runs on `macos-26` because that image carries Xcode 26, which the project is built
and tested with. `macos-15` tops out at Xcode 16.

`packaging/cask/sshdrive.rb` is the source of every cask stanza. `scripts/set-version.sh`
stamps its `version`. Its `sha256` stays the previous release's, because a DMG's hash cannot
exist before the DMG: the `tap` job writes the real one into the tap only. Nothing is written
back to this repository, so after a release the tap holds a sha256 the repository does not.
The `tap` job also checks the DMG's hash against the `.sha256` the macOS job wrote beside it
and stops if they differ.

## The secrets

Seven repository secrets. None can be created from this repository.

| Secret | What it is |
|---|---|
| `DEVELOPER_ID_P12_BASE64` | the Developer ID Application certificate and its private key, as a base64 `.p12` |
| `DEVELOPER_ID_P12_PASSWORD` | the password that `.p12` was exported with |
| `PROVISIONING_PROFILE_BASE64` | the Developer ID provisioning profile for `org.shirls.sshdrive`, base64 |
| `APP_STORE_CONNECT_KEY_BASE64` | the App Store Connect API key (`.p8`), base64 |
| `APP_STORE_CONNECT_KEY_ID` | that key's id, the `<KEYID>` in `AuthKey_<KEYID>.p8` |
| `APP_STORE_CONNECT_ISSUER` | the issuer uuid, from the Keys page in App Store Connect |
| `TAP_GITHUB_TOKEN` | a fine-grained PAT with `contents: write` on `alecdwm/homebrew-tap` only. The workflow's own `GITHUB_TOKEN` cannot reach another repository |

Produce the first four on the Mac that holds the certificate:

```sh
# 1. The certificate and its key. Keychain Access > My Certificates > the Developer ID
#    Application certificate > right-click > Export > Personal Information Exchange (.p12).
#    Give it a password; that password is DEVELOPER_ID_P12_PASSWORD.
base64 -i DeveloperID.p12 | pbcopy                     # DEVELOPER_ID_P12_BASE64

# 2. The provisioning profile.
base64 -i ~/Developer/SSH_Drive_Developer_ID.provisionprofile | pbcopy

# 3. The App Store Connect API key. appstoreconnect.apple.com > Users and Access >
#    Integrations > App Store Connect API > Team Keys > +. Download the .p8 once;
#    Apple will not offer it again.
base64 -i ~/Developer/AuthKey_XXXXXXXXXX.p8 | pbcopy
```

A key with read-only Developer access is enough to notarize. It cannot create a provisioning
profile (`403 FORBIDDEN_ERROR`); do that in the web UI or with an Admin key.

On the runner the `.p8`, the `.p12` and the profile are decoded into `$RUNNER_TEMP`, used,
and deleted in a step that runs even when the build fails. None is copied into the
repository, the bundle or the DMG; `notarytool` gets the key's path, never its contents.

### The profile must name the signing certificate

A provisioning profile lists the `DeveloperCertificates` it was issued for, and AMFI matches
on the certificate, not only the entitlements. A profile made for a different Developer ID
Application certificate makes every restricted entitlement in the bundle unsatisfied:

```
org.shirls.sshdrive: Unsatisfied entitlements: keychain-access-groups
Disallowing: org.shirls.sshdrive
amfid: ... not valid: Error Domain=AppleMobileFileIntegrityError Code=-413 "No matching profile found"
```

The agent is then SIGKILLed at exec: `open -g` answers `Launchd job spawn failed`, and a
direct run exits 137. Such a build still signs, verifies, **notarizes and staples**, because
notarization does not look at provisioning profiles (measured on macOS 26.4, 2026-09-05).

`release.sh` checks the profile before signing and will not embed one that fails. It then
signs without `keychain-access-groups` and prints a warning, or, with
`RELEASE_REQUIRE_PROFILE=1` (the default wherever `CI` is set), fails the build.

If the account has more than one Developer ID Application certificate, developer.apple.com
lets you pick the wrong one when creating the profile. To see which certificates a profile
names:

```sh
security cms -D -i ~/Developer/SSH_Drive_Developer_ID.provisionprofile \
  | plutil -convert xml1 -o - - \
  | python3 -c 'import hashlib,plistlib,sys; print([hashlib.sha1(c).hexdigest().upper() for c in plistlib.loads(sys.stdin.buffer.read())["DeveloperCertificates"]])'
security find-identity -v -p codesigning        # the SHA-1 to match it against
```

The profile's list must contain the identity `release.sh` signs with, `SIGN_IDENTITY`. That is
a SHA-1 rather than a name, so two certificates with the same name cannot make `codesign`
ambiguous. On CI the workflow reads the hash out of the temporary keychain it imported the
`.p12` into, so the secret and the check cannot drift apart.

### Notarization credentials

`release.sh` takes them in this order.

**An App Store Connect API key**: `NOTARY_KEY` (the `.p8`'s path), `NOTARY_KEY_ID`,
`NOTARY_ISSUER`. This works headless, and CI passes all three from the secrets. `NOTARY_KEY`
defaults to the single `~/Developer/AuthKey_*.p8` on the build machine when there is exactly
one.

**A `notarytool` keychain profile** (`NOTARY_PROFILE`, default `sshdrive-notary`), used only
when the three above are unset and the profile exists. Create it **at the Mac's console**:

```sh
xcrun notarytool store-credentials "sshdrive-notary" \
    --apple-id "<apple-id-email>" --team-id "RWGDZAYBM8" \
    --password "<app-specific-password>"
```

Over ssh it fails with `User interaction is not allowed`, even with the login keychain
unlocked, because writing the item needs interactive authorisation.

With neither, the script stops after the DMG, prints what is missing and exits 0. That is
fine for a build by hand and not something to publish: with `RELEASE_REQUIRE_NOTARIZATION=1`
(the default under CI) the run fails instead.

## Re-running a release

The workflow also runs on `workflow_dispatch`. Start the run **from the tag**, and pass the
same tag as the `tag` input. The helper build runs from the ref the run was started on, so
dispatching from a branch builds that branch's helper against the tag's app.

A re-run replaces the DMG on the existing release (`softprops/action-gh-release` updates
rather than refuses). The `tap` job pushes nothing when the rendered cask is byte-for-byte
what the tap already has.

## Building a release by hand

When CI cannot run, `scripts/release.sh` is the same script. Without `RELEASE_LOCAL=1` it
drives the Mac over ssh from the Linux box; everything happens on the Mac, since the Linux box
has no Xcode, no `codesign`, no `hdiutil` and no `notarytool`.

```sh
scripts/build-helper.sh             # or take the helper workflow's artifacts into Resources/helper
scripts/release.sh build            # Release build, Developer ID signed
scripts/release.sh dmg              # + SSH-Drive-<version>.dmg
NOTARY_KEY_ID=<KEYID> NOTARY_ISSUER=<UUID> \
    scripts/release.sh notarize     # + notarize, staple, sha256
```

With no argument it does all of it in one pass. The DMG and its `.sha256` land in `dist/`
**on the Mac**, and the run prints the two lines the cask needs. Then, by hand:

1. Upload the DMG and the `.sha256` to the GitHub release.
2. Copy `version` and `sha256` into `Casks/sshdrive.rb` in `alecdwm/homebrew-tap`.

The script's environment is documented at its top. The variables that matter here:
`RELEASE_LOCAL`, `MAC_HOST`, `SIGN_IDENTITY`, `RELEASE_PROFILE`, `KEYCHAIN_PATH`,
`NOTARY_KEY`/`NOTARY_KEY_ID`/`NOTARY_ISSUER`, and the two `RELEASE_REQUIRE_*` switches.

## How the release is signed

| | `mac-build.sh signed` | `release.sh` |
|---|---|---|
| configuration | Debug | Release |
| identity | Apple Development | Developer ID Application |
| timestamp | `--timestamp=none` | `--timestamp` (notarization rejects a signature without one; the machine must reach `timestamp.apple.com`) |
| appex entitlements | `…debug.entitlements`, with `com.apple.developer.fileprovider.testing-mode` when the testing profile is present | `…entitlements`: sandbox and app group only |
| appex profile | the FileProvider Testing profile | none, ever |
| agent entitlements | app group + `keychain-access-groups` | the same |
| `com.apple.application-identifier` | never | never |

!!! warning "Never add `com.apple.application-identifier`"
    An executable carrying it may only be launched as an app. AMFI logs a Launch Constraint
    Violation and refuses to let launchd start it, and the agent is a launchd job. Adding it
    to "match the profile properly" breaks the product.

Signing goes inside out, because signing the wrapper seals whatever is inside it:

1. The helper binaries are copied into `Contents/Resources/helper/` first. The darwin helpers
   arrive ad-hoc signed from `build-helper.sh`; notarization rejects the whole app unless
   every Mach-O has a Developer ID signature with the hardened runtime and a timestamp, so
   they are re-signed as `org.shirls.sshdrive.helper` and `manifest.json` is rebuilt, since
   signing changes their bytes.
2. The CLI, askpass and the appex.
3. The app.

## The DMG

```sh
hdiutil create -volname "SSH Drive" -srcfolder <staging> -fs HFS+ -format UDZO
```

The staging directory holds `SSH Drive.app` and a symlink named `Applications` pointing at
`/Applications`. Someone opening the image by hand gets a drag-and-drop install; the cask
ignores the window and takes the app. There is no AppleScript window layout, because a
headless machine has no Finder to do it. The file is `SSH-Drive-<version>.dmg`, matching the
URL in the cask.

The image is signed with the same Developer ID identity, not only stapled. A DMG with a
notarization ticket and no signature of its own is refused on the download path:

```
$ xcrun stapler validate dist/SSH-Drive-0.1.0.dmg
The validate action worked!
$ spctl --assess --type open --context context:primary-signature -v dist/SSH-Drive-0.1.0.dmg
dist/SSH-Drive-0.1.0.dmg: rejected
source=no usable signature
```

Homebrew never sees that, since it reads the app out of the image, but a person who
double-clicks the download does. The finished DMG assesses
`accepted / source=Notarized Developer ID` as a disk image as well as an app.

### Why the DMG is built twice

Stapling a DMG staples the image, not the app inside it. An app dragged out of a DMG stapled
before the app was carries no ticket and needs the network to pass Gatekeeper. So:

1. Zip the app, `notarytool submit --wait` the zip, `stapler staple` the **app**.
2. Rebuild the DMG around the stapled app.
3. `notarytool submit --wait` the **DMG**, `stapler staple` the DMG.

The DMG's sha256 changes between the `dmg` step and the end of `notarize`. The cask must use
the **final** one, which is the one the `tap` job hashes.

## What can go wrong

| Symptom | Cause | Fix |
|---|---|---|
| `check` fails: "the tag is … and VERSION says …" | the tag is not `v$(cat VERSION)` | `scripts/set-version.sh <x.y.z>`, commit, re-tag |
| `check` fails at `scripts/set-version.sh --check` | a stamped file disagrees with `VERSION` | run `scripts/set-version.sh` with the version and commit |
| `release` fails: "the .p12 holds no Developer ID Application identity" | the wrong certificate was exported | re-export the Developer ID Application certificate with its key |
| `release` fails: "RELEASE_REQUIRE_PROFILE=1: refusing to build a release nobody can store a password in" | the profile does not name the signing certificate, or is missing | [check the profile](#the-profile-must-name-the-signing-certificate); re-create it at developer.apple.com for `org.shirls.sshdrive`, selecting the right certificate |
| an installed build is SIGKILLed at exec, `Launchd job spawn failed`, amfid `-413` | a profile for a different certificate was embedded | as above |
| `release` fails: "RELEASE_REQUIRE_NOTARIZATION=1: an unnotarized DMG is not a release." | no notarization credentials | set the three `APP_STORE_CONNECT_*` secrets, or `NOTARY_KEY*` by hand |
| "notarization of … was not accepted", followed by the notary log | Apple rejected the submission (`notarytool` itself exits 0 whatever the verdict) | read the log; an unsigned or untimestamped Mach-O in the bundle is the usual cause. The script stops here because stapling a rejected submission fails later with an unrelated CloudKit error |
| `notarytool store-credentials`: `User interaction is not allowed` | run over ssh | run it at the console, or use the API key |
| creating a profile returns `403 FORBIDDEN_ERROR` | the API key is read-only | use the web UI or an Admin key |
| codesign fails with `errSecInternalComponent` on a runner | the imported key has no partition list, so codesign raises a prompt nobody can answer | the workflow runs `security set-key-partition-list`; keep that step |
| signing fails: "ambiguous (matches multiple identities)" | two certificates share a name | set `SIGN_IDENTITY` to the SHA-1, not the name |
| signing fails: no timestamp | the Mac cannot reach `timestamp.apple.com` | fix the network; notarization needs the timestamp |
| a double-clicked DMG is rejected, `source=no usable signature` | the DMG was stapled but not signed | `release.sh` signs it; check a hand-built DMG was made by the script |
| the build warns "no Resources/helper/manifest.json; this release ships no helper" | the helper was not built | `scripts/build-helper.sh`, or take CI's artifacts into `Resources/helper` |
| `doctor` after install: `quarantine` or `extension registered` fails | the cask `postflight` did not strip the attribute | see [troubleshooting](troubleshooting.md), then fix the cask in `packaging/cask/sshdrive.rb` |
