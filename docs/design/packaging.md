# Packaging, install and release

The four executables ship in one signed, notarized bundle, installed by a Homebrew cask from a tap
and released by a tag-triggered workflow. The one thing to know: every step that registers the
agent or the extension has to be run from the app's own bundle, in a fixed order - assess, strip
quarantine, unregister, open - or the install looks finished while something is dead.

## Build

- An Xcode project with four targets (app/agent, extension, CLI, askpass) plus the
  `SSHDriveCore` local package, and a Rust crate for the helper.
- CI: `xcodebuild archive`, Developer ID sign, `notarytool`, staple, DMG.
- The app bundle embeds a Developer ID provisioning profile, because `keychain-access-groups` on
  the agent is a restricted entitlement ([components and identifiers](components.md)).
- The CLI and askpass are signed with the hardened runtime and no restricted entitlements, so
  their being bare executables reached through a symlink is fine.

## Install: the Homebrew cask

The cask installs `SSH Drive.app` and links `sshdrive` from inside the bundle with the `binary`
stanza.

Launching the app is what registers both the extension (with PlugInKit) and the login item
(through `SMAppService`). Both must be done from the app's own bundle, which a symlinked CLI
cannot do. On launch the app registers its login item, notices the launchd-managed instance
already holds the mach service, and exits. macOS posts a notification that a background item was
added, already enabled, with a switch to turn it off under Login Items. That notification is the
only UI the user ever sees.

### `postflight`

The postflight is a legacy Ruby `postflight do` block of `system_command` calls, not
`postflight_steps`. Homebrew runs `postflight_steps` in a sandbox that denies LaunchServices and
the Mach services behind it (Homebrew/brew#23907), which is every step below except the
quarantine strip: inside it `spctl --assess` printed `internal error in Code Signing subsystem`,
`lsregister -dump` printed `failed to scan /Applications/SSH Drive.app: -10822 from spotlight`,
each `lsregister -f` died `Trace/BPT trap: 5`, and `open -g` failed `-10810 kLSUnknownErr` with
`Couldn't communicate with a helper application` under it (Homebrew 7, macOS 27.0, 2026-09-23,
upgrading 0.1.9 to 0.1.10). The legacy block runs outside the sandbox. Homebrew rejects it in
official taps and keeps it for third-party taps for now, so the cask's caveats say what to run
when an install ran none of this: `open -a "SSH Drive"`, whose launch sweeps the records, forces
the registration and repairs the login item itself, then `sshdrive doctor`.

The steps run in this order:

1. **Assess:** `/usr/sbin/spctl --assess --type execute` on the installed app. The verdict is
   logged; it does not fail the install.
2. **Strip quarantine:** `/usr/bin/xattr -dr com.apple.quarantine` on the bundle
   ([below](#quarantine)).
3. **Sweep and rebuild the LaunchServices records:** one `/bin/sh` step. It reads `lsregister
   -dump`, runs `lsregister -u` on every record path under `org.shirls.sshdrive` that is not the
   installed bundle, and then `lsregister -f -R -trusted` on the installed bundle
   ([below](#stale-launchservices-records)).
4. **Unregister:** run the new bundle once with `SSHDRIVE_AGENT_ROLE=unregister`, which calls
   `SMAppService.unregister()`, waits, and exits ([upgrades](#upgrades)).
5. **Open:** `open -g -a "SSH Drive"`, which registers again.

`sshdrive doctor` runs the last step on its own. The unregister and open come after the
assess-and-strip pair because a quarantined bundle registers no plugin however many times it is
opened, and after the sweep because a registration answered from another copy's record registers
nothing new. A developer replacing the bundle by hand has to run steps 3 to 5 too.

Step 1 spells the verbosity flag `-v`: macOS 27's `spctl` rejects `--verbose=4` and prints its
usage instead of a verdict.

### Quarantine

Homebrew leaves `com.apple.quarantine` on the installed bundle, and LaunchServices registers no
plugin of a quarantined bundle that no person has launched; `open -g` is not an assessed launch
(MQ-061, gotcha 99).

Nothing else shows it. The agent runs, because launchd starts the main executable directly, and
the login item registers. Meanwhile `pluginkit -m` prints nothing of ours, `doctor` fails
"extension registered" and "file provider domains" ("The application cannot be used right now"),
and `fileproviderd` logs `getDomainsForProviderIdentifier((null)) failed: FP -2001 Underlying FP
-2014` (provider not found, application extension not found). `pluginkit -a <appex>` registers it
until the next launch wipes that again; `xattr -dr com.apple.quarantine` followed by `open -g`
registers it durably.

Stripping the attribute relocates Gatekeeper rather than bypassing it: the DMG was assessed on
the download path, the notarization ticket is stapled to the app inside it, and the postflight
repeats the assessment on the installed copy first. What is given up is the one-time "downloaded
from the Internet" dialog, which `open -g` shows to nobody anyway.

- `doctor` has a `quarantine` check, ordered before "extension registered" because it is the
  ordinary cause of that one failing. Its remedy is the two commands above.
- The agent logs the same thing once per launch when its own bundle is quarantined.

### Stale LaunchServices records

LaunchServices keys its records on the bundle identifier, and it holds one per path. A record for
a second copy of `SSH Drive.app` answers every registration of the installed one. The second copy
is the DMG: the app is opened once from `/Volumes/SSH Drive/SSH Drive.app`, the volume is
detached, and the record stays behind it.

While that record is there, `lsd` answers every registration of `/Applications/SSH Drive.app` -
the postflight's own `lsregister -f -R -trusted` included - with
`SecStaticCodeCreateWithPath(<private>) failed with error -67028`, `skipping registration of an
incomplete bundle` and `Registration succeeded, but did not actually register anything new;
returning existing bundle`, and `pkd` says `No plugins found to match query`. PlugInKit discovers
no appex, so the symptoms are the ones [quarantine](#quarantine) produces - `pluginkit -m`
silent, `doctor` failing "extension registered" and "file provider domains" - on a bundle
carrying no quarantine attribute at all (MQ-081, gotcha 107).

`lsregister -u` on the stale path drops that record, and `lsregister -f -R -trusted` on the
installed bundle then rebuilds its own; the appex is registered on the next launch. Unlike
`pluginkit -a`, that survives the launch after it. The sweep has to come first: the force on its
own is one of the registrations the stale record answers. Three things do it:

- the cask's `postflight`, before its unregister and open, so an install never leaves the appex
  hidden;
- the app launch itself. After the login item answers, the launch asks PlugInKit whether it knows
  the extension, and when the answer is nothing it unregisters every record path that is not its
  own bundle, forces its own registration **once**, and waits up to 5 s, polling every 0.5 s, for
  the appex to appear. The outcome is logged either way.
- `doctor`'s `launch services records` check, ordered before "extension registered" for the same
  reason `quarantine` is, lists every other record path and gives the `lsregister -u` command for
  each.

### `uninstall` stanza

Homebrew runs a cask's `uninstall` directives on `brew upgrade` and `brew reinstall` as well as
on `brew uninstall`, so nothing destructive may live there. The stanza only stops the agent:

```ruby
signal: ["TERM", "org.shirls.sshdrive.agent"]
```

- It names the launchd **label**, not the bundle id: Homebrew matches the string against
  `launchctl list` output, where the bundle id never appears.
- It is deliberately not `launchctl:`. That directive boots the label out of launchd while
  `SMAppService` and the background-task database still consider the login item enabled, so an
  app launch that registered "only if needed" would do nothing and the mach service would stay
  dead until the next login. A TERM leaves the launchd registration alone.
- The agent handles TERM itself, runs the same shutdown as `sshdrive agent stop`, and exits 0
  (gotcha 94).

### `KeepAlive`

The plist sets `KeepAlive` to `SuccessfulExit` false, not plain `true`.

| Exit | Plain `true` | `SuccessfulExit` false |
|---|---|---|
| Clean (TERM, `agent stop`) | Relaunched at once, from whatever bundle sits at the path - mid-upgrade, the old one about to be deleted; `agent stop` could stop nothing | Stays down until the next mach lookup |
| Crash or death by signal | Relaunched | Relaunched at once |

The lookup that brings the agent back after an upgrade normally finds the new bundle in place. If
it lands during the swap and starts the old bundle, the agent's watch on its own executable
([handover](#handover)) catches the replacement, it exits cleanly again, and the next lookup
starts the new one.

## Upgrades

Locations, domains, the local replica and pending uploads all survive an upgrade untouched. A
pending upload can be re-offered after the replacement, so the same write may arrive twice; the
conflict check makes that safe (gotcha 97).

### Unregister, then register

The app calls `SMAppService.register()` unconditionally on every launch, since it is idempotent,
rather than checking `status` first. But registering is not repairing.

Homebrew deletes the app and installs the new one, and a login item whose bundle was deleted and
put back keeps its enabled status while launchd can no longer resolve the program: every spawn
fails with `Could not find and/or execute program specified by service` and
`copy_bundle_path(...) error 0x6f`, on a 10 s retry, for good. `register()` keeps returning
success throughout, because to `SMAppService` the item is still enabled. Only `unregister()`
clears it (MQ-062). Hence postflight steps 3 and 4.

### The `unregister` role waits, then waits a 5 s grace

`SMAppService.unregister()` returns, and `status` says `notRegistered`, while launchd is still
spawning the old record. A `register()` inside that window leaves the job carrying the previous
bundle's launch constraint: every spawn dies `EXC_CRASH (SIGKILL (Code Signature Invalid))` with a
`Launch Constraint Violation` on a 10 s retry, for ever, while the mach service accepts
connections and answers no command (MQ-063, gotcha 93).

- The role polls `launchctl print` until the service is gone.
- That is not sufficient on its own: the poll can answer "gone" 7 ms after `unregister()` returns
  and a register 110 ms later is constrained anyway. So the role then waits
  `AgentLifecycle.unregisterGraceSeconds` (5 s), an interval that worked, not a measured boundary.

The two together are what make the cask's back-to-back postflight steps safe.

### The launch verifies what it registered

Nothing in `register()`, `SMAppService.status` or the mach lookup distinguishes a job holding a
constraint it cannot satisfy; only asking the agent a question and getting no answer does.
`AgentLifecycle.registerAndVerify`:

1. registers;
2. pings the mach service for up to 10 s;
3. on silence, logs the job as stuck, runs the unregister-and-wait above, registers again and asks
   again;
4. repairs up to three times before reporting failure.

One repair is not always enough: on macOS 26.4.1 a register made 100 ms after the grace died the
same way, and the second repair started the agent (2026-09-23).

The constraint comes from the bundle's signature, so an upgrade that changes signing certificate
is the one that hits this; an ordinary version bump does not.

### Handover

Upgrades replace the bundle under a running agent and extension. The system kills the extension
and relaunches it from the new bundle.

The agent watches its own executable with a vnode dispatch source. When the executable is deleted
or replaced, the agent waits until:

- the bundle at its path is readable,
- its `Info.plist` parses, and
- its main executable is a different inode from the one the agent is running.

Then it exits cleanly, and the next mach lookup starts the new build (see
[`KeepAlive`](#keepalive)). The checks mean it never hands over to a half-copied bundle and never
waits forever on a `brew reinstall` of the same version. Pending uploads are held by the system and survive.

## Removal

Homebrew runs the `uninstall` stanza, then deletes the app, then runs `zap`. By the time `zap`
runs there is no `sshdrive` and no provider left to call `NSFileProviderManager.remove(domain)`,
so domain removal cannot be automated from the cask.

What `zap` does and cannot do:

- It deletes the group container and the launch-agent registration. `launchctl:` is right here,
  since nothing is coming back.
- It cannot delete the keychain items. They live in the data-protection keychain, which no file
  removal reaches and no cask directive addresses, and the only executable that could delete them
  is gone. `sshdrive remove --all` deletes them; without it they are orphaned until a later
  install's `add` overwrites them.
- It does not clear the entry under Login Items. That is the system's own record and goes away
  once the system finds the bundle missing, sometimes not before the next login.

!!! warning "Run `sshdrive remove --all` before `brew uninstall`"
    The cask's `caveats`, the docs and `sshdrive doctor` all say this. A user who skips it is left
    with sidebar entries for a provider that no longer exists, shown as unavailable, until a
    reinstall. On its first launch the reinstalled app removes every domain whose identifier is
    not in `config.json`, or every domain of ours when the container is gone too.

## The Local Network prompt

The agent dials the server, and when the server's address is on the user's own network macOS asks
*"Allow “SSH Drive” to find devices on local networks?"* in the app's name, once, on first connect
(MQ-069, gotcha 57). For this app that is the ordinary case: a NAS is exactly a device on the
local network.

Nothing can pre-arm it: no entitlement suppresses it, and a launchd agent has no window to put it
over. So `add` mentions it, `sshdrive doctor` names it when a location is offline, and the cask's
`caveats` say it once. A refusal is harmless for a server reached off the LAN and fatal for one on
it; the fix is System Settings > Privacy & Security > Local Network.

## Repository and hosting

| What | Where | Notes |
|---|---|---|
| Source, design docs, issues, CI | `github.com/alecdwm/sshdrive` | Design pages and user docs under `docs/`. |
| Release binaries | GitHub Releases on the same repo | The workflow attaches the notarized, stapled `SSH-Drive-<version>.dmg` plus a `.sha256`. Tags `v1.2.3`. |
| Website / user docs | GitHub Pages from `docs/` on `main` | MkDocs, built from `docs/` and deployed by `.github/workflows/pages.yml`. Served at `sshdrive.shirls.org`, the custom domain set in the repository's Pages settings; an Actions deployment needs no `CNAME` file. |
| Homebrew tap | `github.com/alecdwm/homebrew-tap` | Must be a separate repo: `brew tap alecdwm/tap` resolves to `alecdwm/homebrew-tap` by naming convention, so the cask cannot sit inside the main repo without users typing a full URL. Contains `Casks/sshdrive.rb`. |
| Support links baked into the app | `sshdrive --help`, `sshdrive doctor` | Point at the Pages site and the issues tracker. |

- The cask token is `sshdrive`, matching the command and the repository. Homebrew resolves a token
  to the cask file's basename, so the file must be `Casks/sshdrive.rb`. The `ssh-drive` token
  Homebrew would derive from the app name is enforced only in Homebrew's own tap.
- The tap is named `homebrew-tap`, not `homebrew-sshdrive`, so it can hold future casks or
  formulae. If the project gains enough users the cask can be submitted to `homebrew-cask`, and
  `brew install --cask sshdrive` then works without the tap.

User install:

```
brew tap alecdwm/tap
brew install --cask sshdrive
sshdrive add nas
```

## Versioning

The root `VERSION` file holds one version for the whole product. `scripts/set-version.sh` writes it
into every component - the Xcode targets' marketing version, the helper crate, the cask template -
so a bump is one edit and the agent, extension, CLI and helper always report the same string. A
release is that file bumped and a `v<version>` tag pushed.

## Release flow

`.github/workflows/release.yml`, triggered by a `v*` tag, is a Linux job feeding a macOS job.

1. **Build the helper.**
    - The Linux and FreeBSD targets are cross-compiled in a Linux job (the one
      `.github/workflows/helper.yml` runs on ordinary pushes), since `cross` needs Docker and
      GitHub's macOS runners do not provide it.
    - Only `freebsd/x86_64` needs `cross`. The three musl targets link with rustc's own `rust-lld`
      and its bundled self-contained objects (`helper/.cargo/config.toml`), so they build on a
      plain runner with `rustup target add` and no cross C toolchain.
    - `freebsd/aarch64` is not built: it is a tier 3 Rust target with no prebuilt `rust-std`, so it
      cannot be built or even `cargo check`ed without `-Z build-std` on nightly (SQ-065, gotcha 90).
    - The macOS job builds `darwin/arm64` natively with `cargo` and ad-hoc signs it with
      `codesign`, because arm64 macOS refuses to run unsigned code even over `ssh`. It collects the
      Linux job's artifacts and records every hash into the app's manifest.
2. `xcodebuild archive` → Developer ID sign (certificate and App Store Connect API key stored as
   repository secrets) → `notarytool submit --wait` → staple → DMG.
3. Upload DMG + sha256 to the GitHub Release.
4. Render `Casks/sshdrive.rb` from a template with the new version, URL and sha256, and push it to
   `alecdwm/homebrew-tap` (a deploy key or fine-grained PAT for that one repo). `brew upgrade`
   then picks it up.
5. Publish the docs site (Pages deploys automatically from `main`).

## Signing and notarization

Three facts about the Apple material, each capable of costing an afternoon (measured
2026-09-05).

### The profile must name the signing certificate

A profile carries the `DeveloperCertificates` it was issued for, and AMFI matches on them as well
as on the entitlements. A Developer ID profile created against a different Developer ID
Application certificate than the signing one makes every restricted entitlement unsatisfied, and
the agent is SIGKILLed at exec; `open -g` returns `Launchd job spawn failed` (MQ-064, gotcha 91).
Such a build signs, verifies, notarizes and staples, because notarization never looks at
provisioning profiles. Adding `com.apple.application-identifier` to match the profile does not
help and cannot be done anyway.

So `scripts/release.sh` compares the profile's certificate hashes against the signing identity
before signing, and drops `keychain-access-groups` with a loud warning rather than embed a
profile that would kill the agent.

### The DMG is signed as well as stapled

A DMG that carries a notarization ticket but no signature of its own is refused on the download
path: `spctl --assess --type open --context context:primary-signature` answers `rejected /
source=no usable signature` however good the ticket is. Homebrew never sees this, since it reads
the app out of the image, but a person who double-clicks the download does. `release.sh`
`codesign`s the DMG with the same Developer ID identity before submitting it.

### Notarization uses an API key

`notarytool store-credentials` cannot run over ssh: it writes a login-keychain item through an
interactive authorisation and fails with "User interaction is not allowed" even with the keychain
unlocked (gotcha 92). A headless release authenticates with an App Store Connect API key
(`--key`, `--key-id`, `--issuer`). The `.p8` stays on the build machine and is never copied into
the repository, the bundle or the DMG. The `--keychain-profile` form is the fallback for a profile
someone created at the console.

A read-only API key is enough to notarize. It cannot create a provisioning profile
(`403 FORBIDDEN_ERROR`); that stays a web-UI job.
