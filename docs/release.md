# Cutting a release

A release is a `v*` tag. Pushing it runs `.github/workflows/release.yml`, which builds,
signs, notarizes and staples the app, attaches `SSH-Drive-<version>.dmg` to a GitHub
release, and pushes the updated cask to `alecdwm/homebrew-tap`.

```sh
scripts/set-version.sh 0.2.0        # VERSION, project.yml, the crate, Cargo.lock, Version.swift, the cask
git commit -am "Bump to 0.2.0"
git tag v0.2.0
git push origin main v0.2.0
```

The tag is only a trigger: the version comes from the `VERSION` file, and the workflow
refuses to build unless the tag is exactly `v$(cat VERSION)` and every location
`scripts/set-version.sh` stamps agrees with it.

## What the workflow does

| Job | Where | What |
|---|---|---|
| `check` | `swift:6.3-noble` on ubuntu | the tag-and-`VERSION` check, `scripts/set-version.sh --check`, `swift test` in `Packages/SSHDriveCore` |
| `helper` | `.github/workflows/helper.yml` | `cargo test`, `cargo clippy`, then the five helper binaries and `manifest.json` as the `helper-bundle` artifact |
| `release` | `macos-26` | `scripts/release.sh` with the secrets below: xcodegen, `xcodebuild -configuration Release`, embed the helper, Developer ID sign with the hardened runtime, DMG, notarize, staple, `spctl --assess`. Uploads the DMG and creates the GitHub release |
| `tap` | ubuntu | renders `packaging/cask/sshdrive.rb` with the new version and the DMG's sha256 and pushes it to `alecdwm/homebrew-tap` as `Casks/sshdrive.rb`, commit message `sshdrive <version>` |

Nothing is published before the tests are green: `release` needs both `check` and
`helper`, and `helper` builds nothing until its own `cargo test` and `cargo clippy` pass.

The macOS job runs on `macos-26` because that is the image carrying Xcode 26, which is
what the project is built and tested with. `macos-15` tops out at Xcode 16.

`packaging/cask/sshdrive.rb` is the cask's source of truth: every stanza is edited there
and travels with the release. Its `version` is stamped by `scripts/set-version.sh`; its
`sha256` is the previous release's until the `tap` job replaces it, because the sha256 of
a DMG cannot exist before the DMG does. Nothing is written back to this repository, so
after a release the tap holds a sha256 the repository does not.

## The secrets

Seven repository secrets, none of them creatable from this repository.

| Secret | What it is |
|---|---|
| `DEVELOPER_ID_P12_BASE64` | the Developer ID Application certificate and its private key, as a base64 `.p12` |
| `DEVELOPER_ID_P12_PASSWORD` | the password that `.p12` was exported with |
| `PROVISIONING_PROFILE_BASE64` | the Developer ID provisioning profile for `org.shirls.sshdrive`, base64 |
| `APP_STORE_CONNECT_KEY_BASE64` | the App Store Connect API key (`.p8`), base64 |
| `APP_STORE_CONNECT_KEY_ID` | that key's id, the `<KEYID>` in `AuthKey_<KEYID>.p8` |
| `APP_STORE_CONNECT_ISSUER` | the issuer uuid, from the Keys page in App Store Connect |
| `TAP_GITHUB_TOKEN` | a fine-grained PAT with `contents: write` on `alecdwm/homebrew-tap` only. The workflow's own `GITHUB_TOKEN` cannot reach another repository |

Producing the first four, on the Mac that holds the certificate:

```sh
# 1. the certificate and its key. Keychain Access > My Certificates > the Developer ID
#    Application certificate > right-click > Export > Personal Information Exchange (.p12).
#    Give it a password; that password is DEVELOPER_ID_P12_PASSWORD.
base64 -i DeveloperID.p12 | pbcopy                     # DEVELOPER_ID_P12_BASE64

# 2. the provisioning profile
base64 -i ~/Developer/SSH_Drive_Developer_ID.provisionprofile | pbcopy

# 3. the App Store Connect API key. appstoreconnect.apple.com > Users and Access >
#    Integrations > App Store Connect API > Team Keys > +. Download the .p8 once; Apple will not offer it again.
base64 -i ~/Developer/AuthKey_XXXXXXXXXX.p8 | pbcopy
```

A key with read-only Developer access is enough to notarize. It is not enough to *create*
a provisioning profile: that returns `403 FORBIDDEN_ERROR` and has to be done in the web
UI or with an Admin key.

The `.p8` and the `.p12` are decoded into `$RUNNER_TEMP` on the runner, used, and deleted
in a step that runs even when the build fails. Neither is copied into the repository, the
bundle or the DMG; `notarytool` is given the key's path, never its contents.

### The profile has to name the signing certificate

This is the one that will cost an afternoon, so `release.sh` checks it before signing and
refuses to embed a profile that fails. On CI a failed check fails the build:
`RELEASE_REQUIRE_PROFILE` defaults to 1 wherever `CI` is set.

A provisioning profile carries the list of `DeveloperCertificates` it was issued for, and
AMFI matches the certificate, not just the entitlements. A profile created against a
*different* Developer ID Application certificate than the one signing the bundle is not
merely ignored: every restricted entitlement in the bundle becomes unsatisfied,
`taskgated-helper` logs

```
org.shirls.sshdrive: Unsatisfied entitlements: keychain-access-groups
Disallowing: org.shirls.sshdrive
amfid: ... not valid: Error Domain=AppleMobileFileIntegrityError Code=-413 "No matching profile found"
```

and the agent is SIGKILLed at exec - `open -g` answers `Launchd job spawn failed`, and a
direct run exits 137. Such a build signs, verifies, **notarizes and staples** perfectly
and then will not launch (measured on macOS 26.4, 2026-09-05). Notarization does not look
at provisioning profiles at all.

If the account has more than one Developer ID Application certificate, the profile page at
developer.apple.com will happily let you pick the wrong one. To check which certificate a
profile is for:

```sh
security cms -D -i ~/Developer/SSH_Drive_Developer_ID.provisionprofile \
  | plutil -convert xml1 -o - - \
  | python3 -c 'import hashlib,plistlib,sys; print([hashlib.sha1(c).hexdigest().upper() for c in plistlib.loads(sys.stdin.buffer.read())["DeveloperCertificates"]])'
security find-identity -v -p codesigning        # the SHA-1 to match it against
```

The two lists must intersect at the identity `release.sh` signs with (`SIGN_IDENTITY`,
which is a SHA-1 rather than a name so that two certificates with the same name cannot
make `codesign` ambiguous). On CI the workflow reads that hash out of the temporary
keychain it imported the `.p12` into, so the secret and the check cannot drift apart.

### Notarization credentials

**An App Store Connect API key.** The route that works on a headless machine, and the one
`release.sh` prefers: `NOTARY_KEY` (the `.p8`'s path), `NOTARY_KEY_ID`, `NOTARY_ISSUER`.
CI passes all three from the secrets above.

**A `notarytool` keychain profile**, the fallback when those three are unset:

```sh
xcrun notarytool store-credentials "sshdrive-notary" \
    --apple-id "<apple-id-email>" --team-id "RWGDZAYBM8" \
    --password "<app-specific-password>"
```

It must be run **at the Mac's console**. Over ssh it fails with `User interaction is not
allowed` even with the login keychain explicitly unlocked, because writing the item needs
an interactive authorisation the ssh session cannot provide.

With no credentials at all the script stops after the DMG and prints what is missing,
which is a useful state to build by hand and not one to publish: under CI
`RELEASE_REQUIRE_NOTARIZATION` defaults to 1 and the run fails instead.

## Re-running a release

The workflow is also `workflow_dispatch`. Start the run **from the tag** and pass the same
tag as the `tag` input: the helper build runs from the ref the run was started on, so
dispatching from a branch would build that branch's helper against the tag's app.

`softprops/action-gh-release` updates an existing release rather than refusing, so a
re-run replaces the DMG on the same tag. The `tap` job pushes nothing when the rendered
cask is byte-for-byte what the tap already has.

## Building a release by hand

`scripts/release.sh` is the same script CI runs. Without `RELEASE_LOCAL=1` it drives the
Mac over ssh from the Linux box the repo is edited on, which is the fallback when CI
cannot run:

```sh
scripts/build-helper.sh             # or take the helper workflow's artifacts into Resources/helper
scripts/release.sh build            # Release build, Developer ID signed
scripts/release.sh dmg              # + SSH-Drive-<version>.dmg
NOTARY_KEY_ID=<KEYID> NOTARY_ISSUER=<UUID> \
    scripts/release.sh notarize     # + notarize, staple, sha256
```

With no argument it does all of it in one pass. Everything happens on the Mac: there is no
Swift toolchain, no `codesign` and no `hdiutil` on the Linux box. The DMG and its
`.sha256` land in `dist/` **on the Mac**, and the run prints the two lines the cask needs.

Its environment is documented at the top of the script. The ones that matter here:
`RELEASE_LOCAL`, `MAC_HOST`, `SIGN_IDENTITY`, `RELEASE_PROFILE`, `KEYCHAIN_PATH`,
`NOTARY_KEY`/`NOTARY_KEY_ID`/`NOTARY_ISSUER`, and the two `RELEASE_REQUIRE_*` switches.

Then, by hand: upload the DMG and the `.sha256` to the GitHub release, and copy `version`
and `sha256` into `Casks/sshdrive.rb` in `alecdwm/homebrew-tap`.

## What the script signs, and why it is not what `mac-build.sh` signs

| | `mac-build.sh signed` | `release.sh` |
|---|---|---|
| configuration | Debug | Release |
| identity | Apple Development | Developer ID Application |
| timestamp | `--timestamp=none` | `--timestamp` (notarization rejects a signature without one; the machine must reach `timestamp.apple.com`) |
| appex entitlements | `…debug.entitlements`, with `com.apple.developer.fileprovider.testing-mode` when the testing profile is present | `…entitlements`: sandbox and app group only |
| appex profile | the FileProvider Testing profile | none, ever |
| agent entitlements | app group + `keychain-access-groups` | the same |
| `com.apple.application-identifier` | never | never |

The last row is not an oversight. An executable carrying
`com.apple.application-identifier` may only be launched as an app; AMFI logs a Launch
Constraint Violation and refuses to let **launchd** start it, and the agent is a launchd
job. Adding the key to "match the profile properly" breaks the product. Both signing
scripts leave it out.

Signing is inside out - CLI, askpass, appex, then the app - because signing the wrapper
seals whatever is inside it. The helper binaries are copied into
`Contents/Resources/helper/` *before* any of that, for the same reason.

## The DMG

`hdiutil create -volname "SSH Drive" -srcfolder <staging> -fs HFS+ -format UDZO`, where
the staging directory holds `SSH Drive.app` and a symlink named `Applications` pointing at
`/Applications`. That is the whole layout: anyone who opens the image by hand gets a
drag-and-drop install, and the cask ignores the window entirely and uses the app.

No AppleScript window dressing. A headless machine has no Finder to lay icons out with.

The file is `SSH-Drive-<version>.dmg`, matching the URL in the cask.

**The image is signed too, not only stapled.** A DMG that carries a notarization ticket
and no signature of its own is refused on the download path:

```
$ xcrun stapler validate dist/SSH-Drive-0.1.0.dmg
The validate action worked!
$ spctl --assess --type open --context context:primary-signature -v dist/SSH-Drive-0.1.0.dmg
dist/SSH-Drive-0.1.0.dmg: rejected
source=no usable signature
```

Homebrew never sees that - it reads the app out of the image - but a person who
double-clicks the download does. `release.sh` `codesign`s the image with the same
Developer ID identity before submitting it, and the finished artefact assesses
`accepted / source=Notarized Developer ID` as a disk image as well as as an app.

### Stapling, and why the DMG is built twice

`stapler staple` on a DMG staples the *image*. An app dragged out of a DMG that was
stapled before the app inside it was carries no ticket of its own and needs the network to
pass Gatekeeper. So the order is:

1. zip the app, `notarytool submit --wait` the zip, `stapler staple` the **app**
2. rebuild the DMG around the now-stapled app
3. `notarytool submit --wait` the **DMG**, `stapler staple` the DMG

The DMG's sha256 therefore changes between the `dmg` step and the end of `notarize`; the
cask must use the **final** one, which is the one the `tap` job hashes.

## After the workflow is green

1. The GitHub release carries `SSH-Drive-<version>.dmg` and its `.sha256`, and
   `alecdwm/homebrew-tap` carries a `sshdrive <version>` commit.
2. **Install through the cask on a real Mac and check the extension registers.** This is
   the step no runner and no VM can stand in for: `brew install --cask sshdrive`, then
   `sshdrive doctor` - `quarantine` and `extension registered` must both be `ok`, and
   `file provider domains` must not say *The application cannot be used right now*.
   LaunchServices registers no plugin of a bundle still carrying `com.apple.quarantine`
   that no person has ever launched, which is why the cask's `postflight` assesses the app
   with `spctl` and then strips the attribute. Also check that
   `xattr -p com.apple.quarantine "/Applications/SSH Drive.app"` prints nothing.
3. `brew upgrade --cask sshdrive` on a machine that already has it, and check that the
   sidebar entries, the cached files and any pending upload are still there.
   `scripts/release.sh install` (or `RELEASE_INSTALL=1 scripts/release.sh`) reproduces the
   same stop/replace/`unregister`+`open -g` sequence on the build Mac, for checking the
   upgrade path against a build that is not in a cask yet.
4. `brew style` and `brew audit --new --cask alecdwm/tap/sshdrive` need a Homebrew
   install, which neither the Linux box nor the build VM has. The `tap` job runs `ruby -c`
   on the rendered cask, which is not the same check.
