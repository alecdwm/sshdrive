# Cutting a release

What `scripts/release.sh` does, what Apple material it needs, and what has to be true
before any of it works. DESIGN.md section 10 is the design; this is the procedure.

## The short version

```sh
# from the Linux box the repo is edited on
scripts/build-helper.sh                     # or take CI's artifacts into Resources/helper
scripts/release.sh build                    # Release build, Developer ID signed
scripts/release.sh dmg                      # + SSH-Drive-<version>.dmg
NOTARY_KEY_ID=<KEYID> NOTARY_ISSUER=<UUID> \
    scripts/release.sh notarize             # + notarize, staple, sha256
```

`scripts/release.sh` with no argument does all of it in one pass. Everything happens on
the Mac over ssh: there is no Swift toolchain, no `codesign` and no `hdiutil` on the Linux
box. The DMG and its `.sha256` land in `dist/` **on the Mac**.

## The Apple material

Four things, none of them in this repository and none of them creatable from it.

| What | Where it lives | What breaks without it |
|---|---|---|
| **Developer ID Application** certificate + private key | the Mac's login keychain | nothing signs; `codesign` cannot find the identity |
| **Developer ID provisioning profile** for `org.shirls.sshdrive` | `~/Developer/SSH_Drive_Developer_ID.provisionprofile` on the Mac | `keychain-access-groups` is dropped: the build runs but cannot use a stored password or key passphrase |
| **App Store Connect API key** (`.p8`) + key id + issuer id | `~/Developer/AuthKey_<KEYID>.p8` on the Mac | no notarization; Gatekeeper refuses the download on every other Mac |
| the helper binaries | `Resources/helper/` (from `scripts/build-helper.sh` or CI) | the release ships no helper and every location tops out at the sweep tier |

The `.p8` stays on the Mac. `scripts/release.sh` passes its **path** to `notarytool` and
never reads it, never copies it into the repository, the bundle or the DMG.

### The profile has to name the signing certificate

This is the one that will cost an afternoon if it is not checked, so `release.sh` checks
it before signing and refuses to embed a profile that fails.

A provisioning profile carries the list of `DeveloperCertificates` it was issued for. AMFI
matches the certificate, not just the entitlements. A profile created against a *different*
Developer ID Application certificate than the one signing the bundle is not merely ignored:
every restricted entitlement in the bundle becomes unsatisfied, `taskgated-helper` logs

```
org.shirls.sshdrive: Unsatisfied entitlements: keychain-access-groups
Disallowing: org.shirls.sshdrive
amfid: ... not valid: Error Domain=AppleMobileFileIntegrityError Code=-413 "No matching profile found"
```

and the agent is SIGKILLed at exec — `open -g` answers `Launchd job spawn failed`, and a
direct run exits 137. Such a build signs, verifies, **notarizes and staples** perfectly and
then will not launch (measured 2026-09-05; `docs/spikes/milestone-10.md`). Notarization
does not look at provisioning profiles at all.

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
which is a SHA-1 rather than a name so that two certificates with the same name cannot make
`codesign` ambiguous).

### Notarization credentials: two routes

**An App Store Connect API key.** The route that works on a headless machine, and the one
`release.sh` prefers:

```sh
NOTARY_KEY_ID=<KEYID> NOTARY_ISSUER=<ISSUER-UUID> scripts/release.sh notarize
```

`NOTARY_KEY` defaults to the single `~/Developer/AuthKey_*.p8` on the Mac; pass it
explicitly if there is more than one. A key with read-only "Developer" access is enough to
notarize (it is not enough to *create* a provisioning profile — that returns
`403 FORBIDDEN_ERROR` and has to be done in the web UI or with an Admin key).

**A `notarytool` keychain profile.** Section 10 assumed this one:

```sh
xcrun notarytool store-credentials "sshdrive-notary" \
    --apple-id "<apple-id-email>" --team-id "RWGDZAYBM8" \
    --password "<app-specific-password>"
```

It must be run **at the Mac's console**. Over ssh it fails with `User interaction is not
allowed` even with the login keychain explicitly unlocked, because writing the item needs
an interactive authorisation the ssh session cannot provide. `release.sh` falls back to
`--keychain-profile sshdrive-notary` when the three API-key variables are unset and the
profile already exists, and prints both recipes when neither is available.

With no credentials at all the script stops **cleanly** after the DMG, printing what is
missing. Nothing else in the run fails, and the unnotarized DMG is left in `dist/`.

## What the script signs, and why it is not what `mac-build.sh` signs

| | `mac-build.sh signed` | `release.sh` |
|---|---|---|
| configuration | Debug | Release |
| identity | Apple Development | Developer ID Application |
| timestamp | `--timestamp=none` | `--timestamp` (notarization rejects a signature without one; the Mac must reach `timestamp.apple.com`) |
| appex entitlements | `…debug.entitlements`, with `com.apple.developer.fileprovider.testing-mode` when the testing profile is present | `…entitlements`: sandbox and app group only |
| appex profile | the FileProvider Testing profile | none, ever |
| agent entitlements | app group + `keychain-access-groups` | the same |
| `com.apple.application-identifier` | never | never |

The last row is not an oversight. An executable carrying `com.apple.application-identifier`
may only be launched as an app; AMFI logs a Launch Constraint Violation and refuses to let
**launchd** start it, and the agent is a launchd job (S1 a1, 2026-09-04). Adding the key to
"match the profile properly" breaks the product. Both signing scripts leave it out.

Signing is inside out — CLI, askpass, appex, then the app — because signing the wrapper
seals whatever is inside it. The helper binaries are copied into
`Contents/Resources/helper/` *before* any of that, for the same reason.

## The DMG

`hdiutil create -volname "SSH Drive" -srcfolder <staging> -fs HFS+ -format UDZO`, where the
staging directory holds `SSH Drive.app` and a symlink named `Applications` pointing at
`/Applications`. That is the whole layout: anyone who opens the image by hand gets a
drag-and-drop install, and the cask ignores the window entirely and uses the app.

No AppleScript window dressing. A headless VM has no Finder to lay icons out with.

The file is `SSH-Drive-<version>.dmg`, matching the URL in the cask and in section 10.1.

**The image is signed too, not only stapled.** A DMG that carries a notarization ticket and
no signature of its own is refused on the download path:

```
$ xcrun stapler validate dist/SSH-Drive-0.1.0.dmg
The validate action worked!
$ spctl --assess --type open --context context:primary-signature -v dist/SSH-Drive-0.1.0.dmg
dist/SSH-Drive-0.1.0.dmg: rejected
source=no usable signature
```

Homebrew never sees that - it reads the app out of the image - but a person who
double-clicks the download does. `release.sh` `codesign`s the image with the same Developer
ID identity before submitting it, and the finished artefact assesses
`accepted / source=Notarized Developer ID` as a disk image as well as as an app.

### Stapling, and why the DMG is built twice

`stapler staple` on a DMG staples the *image*. An app dragged out of a DMG that was stapled
before the app inside it was carries no ticket of its own and needs the network to pass
Gatekeeper. So the order is:

1. zip the app, `notarytool submit --wait` the zip, `stapler staple` the **app**
2. rebuild the DMG around the now-stapled app
3. `notarytool submit --wait` the **DMG**, `stapler staple` the DMG

`release.sh notarize` does all six steps. The DMG's sha256 therefore changes between the
`dmg` step and the end of `notarize`; the cask must use the **final** one, which the script
prints.

## Then the cask

`packaging/homebrew-tap/Casks/sshdrive.rb`, which belongs in the separate repository
`alecdwm/homebrew-tap` (see `packaging/homebrew-tap/README.md`). The script prints the two
lines to update:

```
version "0.1.0"
sha256  "<the final DMG's sha256>"
```

`brew style` and `brew audit --cask` are the real checks and need a Homebrew install, which
neither the Linux box nor the build VM has. `ruby -c` on the file is what can be run here.

Section 10.1 step 4 has CI render the cask from a template and push it to the tap with a
deploy key. Until the tap exists, copy the file by hand.

## Checklist for a real release

1. `swift test` green (`scripts/mac-build.sh test`).
2. Helper binaries present for every target section 10.1 names, and their hashes in
   `Resources/helper/manifest.json`.
3. Version bumped in `Apps/Agent/Info.plist` (`release.sh` reads
   `CFBundleShortVersionString` from it) and in `Apps/CLI/SSHDriveCommand.swift`.
4. `scripts/release.sh` end to end; the run must say `embedded …provisionprofile`, and the
   final `spctl --assess` must say `accepted / source=Notarized Developer ID`.
5. Install the DMG on a **second** account or machine, quarantined, and answer Gatekeeper's
   dialog once. `docs/spikes/milestone-10.md` has the exact steps.
6. Tag `v<version>`, upload the DMG and the `.sha256` to the GitHub release.
7. Update the cask's `version` and `sha256`, push to `alecdwm/homebrew-tap`.
8. `brew upgrade --cask sshdrive` on a machine that already has it, and check that the
   sidebar entries, the cached files and any pending upload are still there.
   `scripts/release.sh install` (or `RELEASE_INSTALL=1 scripts/release.sh` to run it right
   after `all`) reproduces the same stop/replace/`unregister`+`open -g` sequence over ssh
   on the build Mac itself, for checking the upgrade path before there is a cask to upgrade
   through.
