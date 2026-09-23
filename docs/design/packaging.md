# Packaging, install and release

How the four executables are built into one bundle, how Homebrew installs
and upgrades it, and where the released artifacts come from.

- Xcode project with four targets (app/agent, extension, CLI, askpass) plus
  the `SSHDriveCore` local package, and a Rust crate for the helper.
- CI: `xcodebuild archive`, Developer ID sign, `notarytool`, staple, DMG.
  The app bundle embeds a Developer ID provisioning profile because
  `keychain-access-groups` on the agent is a restricted entitlement
  ([components and identifiers](components.md)); the CLI and askpass are
  signed with the hardened runtime and no restricted entitlements, so their
  being bare executables reached through a symlink is fine.
- Homebrew cask: installs `SSH Drive.app` and links `sshdrive` from inside the
  bundle via the cask `binary` stanza. The cask's `postflight` runs four
  steps in this order - **assess, strip the quarantine attribute,
  unregister, open** - and `sshdrive doctor` runs the last of them,
  `open -g -a "SSH Drive"`, on its own. Launching the app is
  what registers both the extension with PlugInKit and the login item
  through `SMAppService`, and both must be done from the app's own bundle,
  which a symlinked CLI cannot do. The app, on launch, registers its login
  item (unconditionally, below), notices the launchd-managed instance
  already holds the mach service, and exits. macOS posts a notification that a background
  item was added, with the item already enabled and a switch to turn it
  off under Login Items; that notification is the only "UI" the user
  ever sees.
- **The quarantine attribute has to be removed, or the extension is never
  registered.** Homebrew leaves `com.apple.quarantine` on the installed
  bundle, and LaunchServices declines to register the *plugins* of a
  quarantined bundle that has never been assessed through a launch a person
  saw - which `open -g` is not. Nothing else shows it: the agent runs,
  because launchd starts the main executable directly, and the login item
  registers, so the install looks finished while `pluginkit -m` prints
  nothing of ours, `doctor` fails "extension registered" and "file provider
  domains" ("The application cannot be used right now"), and `fileproviderd`
  logs `getDomainsForProviderIdentifier((null)) failed: FP -2001 Underlying
  FP -2014` - provider not found, application extension not found.
  `pluginkit -a <appex>` registers it and the next launch wipes that
  registration again; `xattr -dr com.apple.quarantine` followed by `open -g`
  registers it durably. Measured on macOS 26.6.2, 2026-09-05, on a
  `brew install --cask sshdrive`; the same quarantined install run as a
  fresh user on macOS 26.4.1 passed, so this is a difference between 26.4
  and 26.6 or between a VM and a real machine, and nothing here claims
  which. So the `postflight` runs
  `/usr/sbin/spctl --assess --type execute` on the installed app first,
  logging its verdict and not failing the install on it, and then
  `/usr/bin/xattr -dr com.apple.quarantine` on the bundle. That is not a
  bypass of Gatekeeper but a relocation of it: the DMG was assessed on the
  download path, the notarization ticket is stapled to the app inside it,
  and the postflight repeats the assessment on the installed copy before
  the attribute goes. What is given up is the one-time "downloaded from the
  Internet" dialog, which `open -g` shows to nobody anyway. `sshdrive
  doctor` carries a **`quarantine`** check, ordered before "extension
  registered" because it is the ordinary cause of that one failing, whose
  remedy is the two commands above; the agent logs the same thing once per
  launch when its own bundle is quarantined.
- Homebrew runs a cask's `uninstall` directives on `brew upgrade` and
  `brew reinstall` as well as on `brew uninstall`, so nothing destructive
  may live there. The `uninstall` stanza only stops the agent, with
  `signal: ["TERM", "org.shirls.sshdrive.agent"]` - the launchd **label**,
  not the bundle id, because Homebrew matches that string
  against `launchctl list` output and the bundle id never appears there -
  and deliberately **not**
  `launchctl:`: that directive boots the label out of launchd while
  `SMAppService` and the background-task database still consider the
  login item enabled, so an app launch that registered "only if needed"
  would do nothing and the mach service would stay dead until the next
  login. A TERM leaves the launchd registration alone. The agent exits
  with status 0 on TERM and on `sshdrive agent stop`, and its plist sets
  `KeepAlive` to `SuccessfulExit` false rather than plain `true`: with
  plain `true` launchd would relaunch the agent the instant it
  exited, from whatever bundle sat at the path at that moment, which
  mid-upgrade is the old one about to be deleted, and `agent stop` could
  not stop anything. With the conditional form a clean exit stays down
  until the next mach lookup, a crash is restarted at once, and the
  lookup that brings the agent back after an upgrade normally finds the
  new bundle in place. If a lookup lands during the swap and starts the
  old bundle, the agent's watch on its own executable (below) catches
  the replacement and it exits cleanly again, and the next lookup starts
  the new one. The app also calls `SMAppService.register()`
  unconditionally on every launch, since it is idempotent, rather than
  checking `status` first - but registering is **not** repairing, and an
  upgrade needs more than that. Homebrew deletes the app and installs the
  new one, and a login item whose bundle has been deleted and put back
  keeps its enabled status while launchd can no longer resolve the
  program: every spawn fails with `Could not find and/or execute program
  specified by service` and `copy_bundle_path(...) error 0x6f`, on a 10 s
  retry, for good. `register()` keeps returning success throughout,
  because as far as `SMAppService` is concerned the item is still
  enabled, so the unconditional register on launch does not clear it.
  Only `unregister()` does. So the upgrade path is
  **unregister, then register**: the cask's `postflight` runs the new
  bundle once with `SSHDRIVE_AGENT_ROLE=unregister`, which calls
  `SMAppService.unregister()` and exits, before the `open -g` that
  registers it again - both of them after the assess-and-strip pair
  above, since a quarantined bundle registers no plugin however many
  times it is opened. The same two steps are what a developer replacing
  the bundle by hand has to run.
- **The `unregister` role waits for launchd to drop the job, and then
  waits a 5 s grace.** `SMAppService.unregister()` returns, and `status`
  says `notRegistered`, while launchd is still spawning the old record; a
  `register()` inside that window leaves the job carrying the previous
  bundle's launch constraint and every spawn dies `EXC_CRASH (SIGKILL (Code
  Signature Invalid))` with a `Launch Constraint Violation` on a 10 s retry,
  for ever, with the mach service accepting connections and answering no
  command. So the role polls `launchctl print` until the service is gone.
  That alone is not sufficient: on 26.4.1 (2026-09-23) the poll answered
  gone 7 ms after `unregister()` returned, the `open -g` 110 ms later was
  constrained anyway, and about 5 s between the two worked first time. The
  grace is `AgentLifecycle.unregisterGraceSeconds`, and the two together
  are what make the cask's back-to-back postflight steps safe.
- **The app launch verifies what it registered, and repairs it.** Nothing
  in `register()`, `SMAppService.status` or the mach lookup distinguishes a
  job holding a constraint it cannot satisfy; only asking the agent a
  question and getting no answer does. So
  `AgentLifecycle.registerAndVerify` registers, polls a ping of the mach
  service for up to 10 s, and on silence logs the job as stuck, runs the
  unregister-and-wait above, registers again and asks again, up to three
  repairs before it reports failure. One repair is not always enough: on
  macOS 26.4.1 a register made 100 ms after the grace died the same way and
  the second repair started the agent (2026-09-23). The constraint is
  captured from the bundle's signature, which is why an upgrade that
  changes signing certificate is the one that hits this and an ordinary
  version bump does not.
- Locations, domains, the local replica and pending uploads all survive
  an upgrade untouched.
  `zap` is where the rest of removal lives, with one limit: Homebrew runs
  the `uninstall` stanza, then deletes the app, then `zap`, so by the time
  `zap` runs there is no `sshdrive` and no provider left to call
  `NSFileProviderManager.remove(domain)`. Domain removal therefore cannot
  be automated from the cask. `zap` deletes the group container and the
  launch-agent registration
  (`launchctl:` is right here, since nothing is coming back). It cannot
  delete the keychain items: they live in the data-protection keychain,
  which no file removal reaches and no cask directive addresses, and by
  the time `zap` runs the only executable that could delete them is
  gone. `sshdrive remove --all` is what deletes them, and a `zap`
  without it leaves orphaned items that a later install's `add` simply
  overwrites. Nor does `zap` clear the entry under Login Items, which is
  the system's own record and goes away once the system finds the bundle
  missing, sometimes not before the next login. So the cask's `caveats`, the docs
  and `sshdrive doctor` all say the same thing: run `sshdrive remove
  --all` before `brew uninstall`. A user who skips it is left with sidebar
  entries for a provider that no longer exists, shown as unavailable,
  until a reinstall, when the app on its first launch removes every domain
  whose identifier is not in `config.json`, or every domain of ours when
  the container is gone too.

**First connect draws the Local Network prompt.** The agent is the process
that dials the server, and when the server's address is on the user's own
network macOS asks *"Allow “SSH Drive” to find devices on local
networks?"* in the app's name, once, the first time it connects (observed
on macOS 26.4, 2026-09-04, against a server on the host's vmnet segment).
That is the ordinary case for this app rather than an edge one: a NAS is
exactly a device on the local network. Nothing can pre-arm it - there is no
entitlement that suppresses it, and a launchd agent has no window to put it
over - so `add` mentions it, `sshdrive doctor` names it when a location is
offline, and the cask's `caveats` say it once. A refusal is harmless for a
server reached off the LAN and fatal for one on it, and the fix is System
Settings > Privacy & Security > Local Network.

## Repository and hosting

Everything lives on GitHub under `alecdwm/sshdrive`, with one small satellite
repo for Homebrew.

| What | Where | Notes |
|---|---|---|
| Source, design docs, issues, CI | `github.com/alecdwm/sshdrive` | Design pages and user docs under `docs/`. |
| Release binaries | GitHub Releases on the same repo | The workflow attaches the notarized, stapled `SSH-Drive-<version>.dmg` plus a `.sha256`. Tags `v1.2.3`. |
| Website / user docs | GitHub Pages from `docs/` on `main` | MkDocs, built from `docs/` and deployed by `.github/workflows/pages.yml`. Served at `sshdrive.shirls.org`, the custom domain set in the repository's Pages settings; an Actions deployment needs no `CNAME` file. |
| Homebrew tap | `github.com/alecdwm/homebrew-tap` | Must be a separate repo: `brew tap alecdwm/tap` resolves to `alecdwm/homebrew-tap` by naming convention, so the cask cannot sit inside the main repo without users typing a full URL. Contains `Casks/sshdrive.rb`. |
| Support links baked into the app | `sshdrive --help`, `sshdrive doctor` | Point at the Pages site and the issues tracker. |

The cask token is `sshdrive`, matching the command and the repository, and
Homebrew resolves a token to the cask file's basename - so the file must be
`Casks/sshdrive.rb`. The `ssh-drive` token Homebrew would derive from the
app name is enforced only for Homebrew's own tap.

Install path for users:

```
brew tap alecdwm/tap
brew install --cask sshdrive
sshdrive add nas
```

**One version, one file.** The root `VERSION` file holds it, and
`scripts/set-version.sh` writes it into every component - the Xcode
targets' marketing version, the helper crate, the cask template - so a bump
is one edit and the agent, the extension, the CLI and the helper always
report the same string. A release is that file bumped and a `v<version>`
tag pushed.

Release flow (`.github/workflows/release.yml`, a Linux job feeding a macOS
job, triggered by a `v*` tag):

1. Build the helper. The Linux and FreeBSD targets are cross-compiled
   in a **Linux job** (the same one `.github/workflows/helper.yml` runs on
   ordinary pushes), since `cross` needs Docker and GitHub's macOS
   runners do not provide it; the macOS job builds `darwin/arm64`
   natively with `cargo`, ad-hoc signs it (`codesign`; arm64 macOS
   refuses to run unsigned code even over `ssh`), collects the Linux
   job's artifacts, and records every hash into the app's manifest.
   Only `freebsd/x86_64` actually needs `cross`: the three musl targets
   link with rustc's own `rust-lld` and its bundled self-contained
   objects (`helper/.cargo/config.toml`), so they build on a plain runner
   with nothing but `rustup target add` and no cross C toolchain at all.
   `freebsd/aarch64` is **not** built: it is a tier 3 Rust target with no
   prebuilt `rust-std`, so it cannot be built - or even `cargo check`ed -
   without `-Z build-std` on nightly, and the target list stops at
   `freebsd/x86_64` for that reason.
2. `xcodebuild archive` → Developer ID sign (certificate and App Store Connect
   API key stored as repository secrets) → `notarytool submit --wait` → staple
   → DMG.
3. Upload DMG + sha256 to the GitHub Release.
4. Render `Casks/sshdrive.rb` from a template with the new version, URL and
   sha256, and push it to `alecdwm/homebrew-tap` (a deploy key or fine-grained
   PAT for that one repo). `brew upgrade` then picks it up.
5. Publish the docs site (Pages deploys automatically from `main`).

Three things about the Apple material, all measured on 2026-09-05 and all
capable of costing an afternoon:

- **The provisioning profile has to name the certificate the bundle is
  signed with.** A profile carries the `DeveloperCertificates` it was
  issued for and AMFI matches on them, not only on the entitlements. A
  Developer ID profile created against a *different* Developer ID
  Application certificate than the signing one is not ignored: every
  restricted entitlement becomes unsatisfied, `taskgated-helper` logs
  `Unsatisfied entitlements: keychain-access-groups` and `Disallowing:
  org.shirls.sshdrive`, `amfid` answers `-413 "No matching profile
  found"`, and the agent is SIGKILLed at exec - `open -g` returns
  `Launchd job spawn failed`. Such a build signs, verifies, **notarizes
  and staples**, and then will not launch: notarization does not look at
  provisioning profiles at all. Adding
  `com.apple.application-identifier` to match the profile "properly" does
  not help and cannot be done anyway. So `scripts/release.sh`
  compares the profile's certificate hashes against the signing identity
  *before* signing, and drops `keychain-access-groups` with a loud
  warning rather than embedding a profile that will kill the agent.
- **The disk image is signed as well as stapled.** A DMG that carries a
  notarization ticket but no signature of its own is refused on the
  download path: `spctl --assess --type open --context
  context:primary-signature` answers `rejected / source=no usable
  signature` however good the ticket is. Homebrew never sees it - it
  reads the app out of the image - but a person who double-clicks the
  download does, so `release.sh` `codesign`s the DMG with the same
  Developer ID identity before submitting it.
- **`notarytool store-credentials` cannot be run over ssh.** It writes an
  item to the login keychain through an interactive authorisation and
  fails with "User interaction is not allowed" from an ssh session even
  with the keychain explicitly unlocked. A headless release therefore
  authenticates with an **App Store Connect API key** - `--key`,
  `--key-id`, `--issuer`, the `.p8` left on the build machine and never
  copied into the repository, the bundle or the DMG - and the
  `--keychain-profile` form is the fallback for a profile someone created
  at the console. A read-only API key is enough to notarize; it is not
  enough to create a provisioning profile (`403 FORBIDDEN_ERROR`), which
  stays a web-UI job.

The tap can be reused for any future casks or formulae; that is why it
is named `homebrew-tap` rather than `homebrew-sshdrive`. If the project gains
enough users, the cask can later be submitted to the main `homebrew-cask`
repository, at which point `brew install --cask sshdrive` works without the
tap.

Upgrades replace the bundle under a running agent and extension. The
extension is killed by the system and relaunched from the new bundle. The
agent watches its own executable with a vnode dispatch source; when it
is deleted or replaced, the agent waits until the bundle at its path is
readable, its `Info.plist` parses, and its main executable is a
different inode from the one the agent is running, so it never hands
over to a half-copied bundle and never waits forever on a
`brew reinstall` of the same version, and then exits cleanly, and the
next mach lookup starts the new build (the `KeepAlive` rule above). Pending
uploads are held by the system and survive.
