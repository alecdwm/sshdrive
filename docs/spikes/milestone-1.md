# Milestone 1 spikes: S1, S3, S4, S6

Runbook for the four spikes DESIGN.md section 12 folds into milestone 1. Section 11 has the
questions; this file has the steps, the answer the design expects, and a line to write what
actually happened. Results go in `results.md`, dated, one entry per sub-question.

Every sub-question is tagged with what it needs:

| Tag | Meaning |
|---|---|
| **VM** | runs on the headless Mac VM, ad-hoc signed, over ssh. No GUI needed. |
| **SIGN** | needs a real Apple signing identity (Apple Development or Developer ID) in the login keychain, and for the restricted entitlements a matching provisioning profile embedded in the bundle. |
| **GUI** | needs a Mac someone is sitting at: Finder windows, context menus, System Settings toggles. |

A sub-question can carry two tags. Where one blocks another, the runbook says so.

---

## 0. Setup

### 0.1 Build and install

From the Linux side:

```
scripts/mac-build.sh app      # sync, xcodegen, xcodebuild, then ad-hoc sign
scripts/mac-build.sh signed   # the same, but signed with the Apple Development identity
                              # and the profiles under ~/Developer on the Mac
```

Use `signed` for anything tagged **SIGN**. It needs the login keychain unlocked, which it
does itself; `codesign` over ssh otherwise fails with `errSecInternalComponent` because it
cannot show a password dialog. Do **not** add `com.apple.application-identifier` to the
app's entitlements: AMFI then refuses to let launchd start the agent at all (results.md,
signed pass).

`xcodebuild` cannot sign the app or the appex without a provisioning profile, because
`com.apple.security.application-groups` and `keychain-access-groups` are restricted
entitlements; the script therefore builds with `CODE_SIGNING_ALLOWED=NO` and ad-hoc signs
the tree itself with the real identifiers and the real entitlement files. It strips
`keychain-access-groups`, which AMFI will not accept on an ad-hoc signature (see S1(d)).

On the Mac:

```
# Only /Applications, and only ever one copy. Two bundles with the same identifier make
# launchd resolve the login item to the wrong one; see results.md 2026-09-04 S1(e).
LSR=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
$LSR -u ~/sshdrive/build/Build/Products/Debug/"SSH Drive.app"
$LSR -u ~/sshdrive/build/Build/Products/Release/"SSH Drive.app"

rsync -a --delete ~/sshdrive/build/Build/Products/Debug/"SSH Drive.app"/ "/Applications/SSH Drive.app"/
$LSR -f -R -trusted "/Applications/SSH Drive.app"

# Registration is not self-repairing once the bundle has been replaced. Always drop it
# first (S1(f)).
SSHDRIVE_AGENT_ROLE=unregister "/Applications/SSH Drive.app/Contents/MacOS/SSH Drive"
open -g -a "/Applications/SSH Drive.app"
"/Applications/SSH Drive.app/Contents/MacOS/sshdrive" doctor
```

`doctor` green is the gate for everything below.

Two things that will otherwise waste an hour:

- **After any agent restart, re-create the fake location** (`sshdrive debug fake remove
  <name>` then `debug fake add <name>`). `FakeTransport` is an in-memory tree, so a
  restarted agent has an empty backend while the index and the system's replica still hold
  the old rows, and the mount answers `Stale NFS file handle` for everything below the
  root.
- **`ls -la` on a mount was a trap until 2026-09-04, and is now safe.** Anything that
  stats `.Trash` used to hang for good: fileproviderd looped on
  `fetch-children-metadata(.trash)` → `itemNotFound` → `materializationFailed` about twice
  a second. Fixed (results.md, 2026-09-04): the domain is added with
  `supportsSyncingTrash = false` and the trash enumerator fails with
  `NSFeatureUnsupportedError` instead of `noSuchItem`. On a build older than that fix, use
  `ls` and `ls -R` only.

### 0.2 The peer code requirement on an unsigned Mac

An ad-hoc signature has no Apple anchor and no team OU, so it satisfies neither form in
`Packages/SSHDriveCore/Sources/XPCProtocols/CodeRequirement.swift` and the agent refuses
every peer, including its own CLI. Debug builds read a replacement from
`~/.sshdrive-spike-peer-requirement` (or `SSHDRIVE_PEER_REQUIREMENT` in the environment,
which launchd scrubs from an `SMAppService` job, so prefer the file):

```
printf '%s' 'identifier "org.shirls.sshdrive" or identifier "org.shirls.sshdrive.cli" or identifier "org.shirls.sshdrive.askpass" or identifier "org.shirls.sshdrive.fileprovider"' \
  > ~/.sshdrive-spike-peer-requirement
"/Applications/SSH Drive.app/Contents/MacOS/sshdrive" agent restart
```

Delete the file to put the build's own requirement back. Release builds ignore both.

### 0.3 Watching

```
log stream --predicate 'subsystem BEGINSWITH "org.shirls.sshdrive"' --style compact
log show --last 5m --predicate 'subsystem BEGINSWITH "org.shirls.sshdrive"' --style compact
```

For the system's half of a question, add `process == "fileproviderd"`, `process == "pkd"`,
`process == "amfid"` or `process == "launchd"`; AMFI's refusals arrive as
`process == "kernel" AND eventMessage CONTAINS "AMFI"`.

### 0.4 The debug hooks

```
sshdrive debug fake add <name> [--files N]        # default 8
sshdrive debug fake remove <name>
sshdrive debug fake list
sshdrive debug tree <name>
sshdrive debug mutate <name> <op> <path> [--to PATH] [--contents TEXT] [--mode OCTAL]
                                               [--target PATH] [--recursive]
        op = create-file | create-dir | create-symlink | write | touch
           | rewrite-invisibly | chmod | rename | delete
sshdrive debug anchor expire <name>
sshdrive debug sweep <name> on|off
sshdrive debug policy <name> <path> eager-keep|lazy|inherit
sshdrive debug index dump <name> [--table items|anchors|roots] [--limit N]
sshdrive debug signal <name>
```

`fake add` seeds the tree, enumerates the root once and adds the domain. Every `mutate`
runs the catch-up sweep and signals the working set afterwards, so a mutation reaches
Finder the way a remote change would.

### 0.5 The extension has to be enabled before any of S3, S4 or S6 runs

A freshly added domain comes up **user-disabled**: `fileproviderctl dump <domain-id>`
prints `(⏹ user-disabled)`, fileproviderd never launches the appex, and every access to
the mount ends in `Operation timed out` with `FP -2011 "Sync is not enabled"` in
fileproviderd's log. Turning it on is System Settings → General → Login Items &
Extensions → File Providers → **SSH Drive**. That switch is in the background-task
database; nothing reachable from a terminal flips it (`pluginkit -e use` sets PlugInKit's
own flag and does not clear `user-disabled`). **GUI**, and it gates everything downstream.

Once the owner has switched SSH Drive on there, the switch is remembered for the
*provider*, and later domains come up enabled: the signed pass (results.md) added and
removed several without touching System Settings again. So this is a once-per-machine
step, not a once-per-domain one.

**Corrected 2026-09-04 (S1 e4):** all of the above is what an **ad-hoc-signed** build
does. With a real signing identity and the embedded profiles, a fresh user's first domain
comes up **enabled** and needs no toggle at all - proved on a second local account that
had never opened System Settings (results.md, "S1(e) on a fresh user install"). Run the
sanity check below before assuming you need the GUI; if `fileproviderctl dump` shows no
`user-disabled`, you do not.

Sanity check before starting a session:

```
fileproviderctl dump | grep -E 'domain:|user-disabled'
pluginkit -m -v -p com.apple.fileprovider-nonui | grep sshdrive
ls -la@ ~/Library/CloudStorage/
```

---

## S1 - the process boundary

### (a) A sandboxed appex reaches the group-prefixed mach service, and launchd starts the agent on that lookup

Two halves; do them separately.

- [ ] **a1. The lookup starts the agent** &mdash; **VM**

  ```
  sshdrive agent stop            # launchd leaves it down: KeepAlive SuccessfulExit=false
  pgrep -f "Contents/MacOS/SSH Drive"        # expect nothing
  sshdrive agent start           # this is only a mach lookup
  pgrep -f "Contents/MacOS/SSH Drive"        # expect a new pid
  log show --last 1m --predicate 'subsystem BEGINSWITH "org.shirls.sshdrive"' --style compact \
    | grep -E 'agent starting from launchd|listening on'
  launchctl print gui/$(id -u)/org.shirls.sshdrive.agent | grep -A6 endpoints
  ```

  Expected (section 3, section 10): the agent is not running after `stop`; the lookup
  spawns it; the job's `endpoints` list carries
  `RWGDZAYBM8.org.shirls.sshdrive.agent` with `active = 1`.

  Result:

- [ ] **a2. The sandboxed appex connects** &mdash; **VM + GUI** (blocked by 0.5) **+ SIGN** (0.2 relaxes it)

  With the domain enabled, list the mount and watch both sides:

  ```
  ls ~/Library/CloudStorage/SSHDrive-<name>/
  log show --last 2m --predicate 'subsystem BEGINSWITH "org.shirls.sshdrive"' --style compact
  ```

  Expected (section 3.1, section 5.2): the appex process appears
  (`ps aux | grep SSHDriveFileProvider`), the agent logs `accepted a peer connection`, and
  the listing is served. The app group on the appex is what allows the lookup at all; a
  sandbox denial would show as `process == "sandboxd"` with `mach-lookup` on
  `RWGDZAYBM8.org.shirls.sshdrive.agent`.

  Result:

### (b) The listener validates the peer's audit token against our code requirement

- [ ] **b1. Both requirement strings parse** &mdash; **VM**

  ```
  printf '%s' '<the appleDevelopment string from CodeRequirement.swift>' > /tmp/req.txt
  csreq -r /tmp/req.txt -b /tmp/req.bin && csreq -r /tmp/req.bin -t
  # and the same for the developerID string
  ```

  Expected: both parse and round-trip. The marker OIDs and the `certificate 1[...] exists`
  syntax were written from documentation and never evaluated (skeleton-notes item 2).

  Result:

- [ ] **b2. A peer that fails the requirement is refused** &mdash; **VM**

  With `~/.sshdrive-spike-peer-requirement` deleted and an ad-hoc build:

  ```
  rm -f ~/.sshdrive-spike-peer-requirement
  sshdrive agent restart
  sshdrive doctor
  ```

  Expected (section 5.2): the connection is dropped and the CLI reports the agent
  unreachable; the agent logs `refusing a peer that does not satisfy the code requirement`.
  A refusal here on an ad-hoc build is the *correct* answer, not a failure.

  Result:

- [ ] **b3. Each real build satisfies its own requirement** &mdash; **SIGN**

  ```
  for x in "SSH Drive.app" \
           "SSH Drive.app/Contents/MacOS/sshdrive" \
           "SSH Drive.app/Contents/MacOS/sshdrive-askpass" \
           "SSH Drive.app/Contents/PlugIns/SSHDriveFileProvider.appex"; do
    codesign -v -R /tmp/req.txt "/Applications/$x"; echo "$x -> $?"
  done
  ```

  Expected: 0 for all four against the Apple Development form for a debug build and the
  Developer ID form for a release build, and non-zero the other way round, so a release
  agent never admits a debug client.

  Result:

- [ ] **b4. A stranger is refused** &mdash; **SIGN**

  Copy `sshdrive` out of the bundle, re-sign it with a different identifier
  (`codesign -f -s <identity> --identifier org.example.notus`), run `doctor` from the copy.
  Expected: refused, with the agent's log line.

  Result:

### (c) A `FileHandle` opened by the extension crosses NSXPC and the agent writes through it

- [ ] **c1. `fetchContents` writes into the extension's handle** &mdash; **VM + GUI** (blocked by 0.5)

  ```
  sshdrive debug fake add nas --files 8
  # enable the domain (0.5), then:
  cat ~/Library/CloudStorage/SSHDrive-nas/Documents/Reports/report-000.txt
  ```

  Expected (section 5.2): the bytes appear; the agent logs the transfer; no
  `NSXPCConnection` error about an unexpected class. This is also the only proof that the
  interface's `Error?` reply parameters and class whitelists are right at runtime
  (skeleton-notes item 9).

  Result:

- [ ] **c2. A cancelled transfer** &mdash; **GUI**

  Cancel a large download from Finder's progress UI. Expected: the extension's `Progress`
  cancels, the agent stops writing, and no half file is left materialized.

  Result:

### (d) Restricted entitlements: the profile, the keychain, and the bare tools

- [ ] **d1. What ad-hoc signing costs** &mdash; **VM**

  ```
  codesign -d --entitlements - --xml "/Applications/SSH Drive.app" | plutil -p -
  ```

  Expected: on the VM build there is no `keychain-access-groups`, because the sign step
  strips it. Put it back and the agent will not exec at all:

  ```
  codesign --force --sign - --identifier org.shirls.sshdrive \
    --entitlements ~/sshdrive/Apps/Agent/SSHDrive.entitlements "/Applications/SSH Drive.app"
  "/Applications/SSH Drive.app/Contents/MacOS/SSH Drive"     # expect Killed: 9
  log show --last 1m --predicate 'process == "amfid"' --style compact | tail
  ```

  Expected: AMFI error `-424`, "The file is adhoc signed but contains restricted
  entitlements".

  Result:

- [ ] **d2. The signed bundle reaches the data-protection keychain** &mdash; **SIGN**

  Needs an Apple Development (debug) or Developer ID (release) certificate plus a
  provisioning profile carrying `keychain-access-groups` for
  `RWGDZAYBM8.org.shirls.sshdrive`, embedded at
  `SSH Drive.app/Contents/embedded.provisionprofile`. Then a `SecItemAdd`/`SecItemCopyMatching`
  round trip from the launchd-started agent with `kSecAttrAccessGroup` set to the group.
  Expected (section 3.1): it works from the agent (the bundle's main executable) and only
  from there.

  Result:

- [ ] **d3. The CLI and askpass launch with no restricted entitlements** &mdash; **VM**

  ```
  codesign -d --entitlements - "/Applications/SSH Drive.app/Contents/MacOS/sshdrive"
  codesign -d --entitlements - "/Applications/SSH Drive.app/Contents/MacOS/sshdrive-askpass"
  otool -s __TEXT __info_plist "/Applications/SSH Drive.app/Contents/MacOS/sshdrive"
  ```

  Expected (section 3.1): empty entitlement dictionaries, and an embedded
  `__TEXT,__info_plist` whose `CFBundleIdentifier` is `org.shirls.sshdrive.cli` /
  `org.shirls.sshdrive.askpass`, which is what the agent's requirement matches.

  Result:

- [ ] **d4. Notarization** &mdash; **SIGN**

  `xcodebuild archive`, Developer ID sign, `notarytool submit --wait`, `stapler staple`.
  Expected: accepted with the profile embedded and the four identifiers as in section 3.1.

  Result:

### (e) `add(domain)` from the launchd agent, and `open -g` registering both halves

- [ ] **e1. `open -g` registers the login item** &mdash; **VM**

  ```
  SSHDRIVE_AGENT_ROLE=unregister "/Applications/SSH Drive.app/Contents/MacOS/SSH Drive"
  open -g -a "/Applications/SSH Drive.app"; echo "open rc=$?"
  launchctl print gui/$(id -u)/org.shirls.sshdrive.agent | head -20
  ```

  Expected (section 10): `open` returns 0 even though the main executable is not an
  `NSApplication` (skeleton-notes item 5); the job exists, `program identifier =
  Contents/MacOS/SSH Drive`, `state = running`, `properties` include `runatload`.

  Result: **PASS**, on the signed VM and again on a never-touched fresh user
  (results.md 2026-09-04, "S1(e) on a fresh user install"). `open rc=0`;
  `gui/502/org.shirls.sshdrive.agent` is `type = Submitted`, `managed_by =
  com.apple.xpc.ServiceManagement`, `state = running`, `program identifier =
  Contents/MacOS/SSH Drive`, `properties = partial import | runatload | resolve program |
  has LWCR`, `semaphores = { successful exit => 0 }`, and the endpoint
  `RWGDZAYBM8.org.shirls.sshdrive.agent` is active. `sshdrive doctor` reports the login
  item `enabled`, not awaiting approval.

- [ ] **e2. `open -g` registers the extension with PlugInKit** &mdash; **VM**

  ```
  pluginkit -m -v -p com.apple.fileprovider-nonui | grep sshdrive
  pluginkit -m -A -i org.shirls.sshdrive.fileprovider -vvv
  ```

  Expected: one line, `Path` under `/Applications/SSH Drive.app`. If a second copy of the
  bundle is registered anywhere, unregister it: two bundles with one identifier break the
  login item (see results.md).

  Result: **PASS.** Exactly one registration,
  `org.shirls.sshdrive.fileprovider(0.1.0)` with `Path = /Applications/SSH Drive.app/
  Contents/PlugIns/SSHDriveFileProvider.appex` and `Parent Bundle = /Applications/SSH
  Drive.app`, its `Timestamp` being the moment of the `open -g`. On the fresh user
  `pluginkit` listed only Apple's three providers beforehand, so `open -g` is what
  registered it - nothing else does.

- [ ] **e3. `add(domain)` creates the mount** &mdash; **VM**

  ```
  sshdrive debug fake add nas --files 8
  ls -la@ ~/Library/CloudStorage/
  fileproviderctl dump | grep -E 'domain:|user-disabled'
  ```

  Expected: `~/Library/CloudStorage/SSHDrive-nas` appears with a
  `com.apple.file-provider-domain-id` xattr, and `fileproviderctl` lists the domain against
  `org.shirls.sshdrive.fileprovider`.

  Result: **PASS.** `ls -la@ ~/Library/CloudStorage/` shows `SSHDrive-nas` carrying
  `com.apple.file-provider-domain-id` (69 bytes,
  `org.shirls.sshdrive.fileprovider/<uuid>`), and `fileproviderctl dump` lists the domain
  under `org.shirls.sshdrive.fileprovider` with `features: repl,` and in the domains
  cache. Mount name is `SSHDrive-<nickname>`, no space and no `SSH Drive - ` prefix.

- [ ] **e4. The domain is actually usable** &mdash; **GUI** (see 0.5)

  Expected: after the System Settings toggle, `fileproviderctl dump <id>` no longer says
  `user-disabled`, the appex process starts, and `ls` on the mount returns the seeded tree.
  Record whether a fresh install really does need that toggle, or whether it is an artefact
  of an ad-hoc signature: if a Developer ID build with a notarized bundle comes up enabled,
  section 10's claim that the notification and the Gatekeeper dialog are the only UI still
  holds; if not, the cask's `caveats` and `sshdrive doctor` have to say so.

  Result: **A fresh install does NOT need the toggle.** Answered on a second local
  account (`sshtest`, uid 502) that had never opened System Settings, against the bundle
  already sitting at `/Applications/SSH Drive.app` - i.e. the post-cask state - with
  nothing run but the section 10 postflight (results.md 2026-09-04, "S1(e) on a fresh
  user install"). After `open -g` and `debug fake add nas`: `fileproviderctl dump`
  contains **no `user-disabled` and no `⏹`** anywhere in its output, our domain's
  `indexer` reads `enabled: yes` / `errors: 0` / `batch-indexed: 10`, fileproviderd
  launched `SSHDriveFileProvider.appex` unprompted, `ls -la` and `ls -R` on the mount
  return the seeded tree at once and `cat` reads a file. 2104 lines of fileproviderd log
  hold no `FP -2011`, no "Sync is not enabled" and no TCC decision naming us.

  So section 10's claim stands: the background-item notification (item already enabled)
  and Gatekeeper's one-time dialog are the only UI, and neither `caveats` nor `sshdrive
  doctor` has to send the user to System Settings. The `user-disabled` state recorded in
  0.5 above was an artefact of the **ad-hoc signature**; a real identity plus the embedded
  profiles comes up enabled. Still unproven, and left to f3 on a notarized artefact:
  a *quarantined* bundle opened by `postflight`, and a Developer ID + notarized chain
  rather than this Apple Development + profile one.

### (f) The agent comes back after the bundle is replaced

- [ ] **f1. TERM, replace, next lookup** &mdash; **VM**

  ```
  kill -TERM $(pgrep -f "Contents/MacOS/SSH Drive")
  rsync -a --delete <new build>/ "/Applications/SSH Drive.app"/
  sshdrive agent start
  ```

  Expected (section 10): the agent exits 0 on TERM, stays down (`KeepAlive
  SuccessfulExit=false`), and the next mach lookup starts the new bundle without a logout.

  Result:

- [ ] **f2. The same with the bundle deleted rather than rewritten** &mdash; **VM**

  `rm -rf` the app, install the new one, then look up the service.

  Expected, and this is the one that actually bites: launchd cannot resolve the login
  item's bundle any more and every spawn fails with `Could not find and/or execute program
  specified by service` / `copy_bundle_path(...) error 0x6f`. `SMAppService.register()`
  keeps returning success because the item is still enabled, so the app's unconditional
  register on launch does **not** repair it; only
  `SSHDRIVE_AGENT_ROLE=unregister` followed by a launch does. Decide from the result
  whether the app should unregister-then-register when it finds the job dead, or whether
  the cask's `postflight` must do it.

  Result:

- [ ] **f3. Real `brew reinstall --cask`** &mdash; **SIGN** (needs a notarized cask artefact)

  Result:

### (g) Homebrew's `signal:` stanza finds the agent

- [ ] **g1. Which string `launchctl list` prints** &mdash; **VM**

  ```
  launchctl list | grep -i sshdrive
  launchctl list org.shirls.sshdrive.agent
  ```

  Expected: this decides section 10 vs section 3.1 (skeleton-notes item 4). Homebrew
  matches the string in its `signal:` stanza against `launchctl list` output, so whatever
  appears in the first column is what the cask must carry.

  Result:

---

## S3 - a minimal replicated extension against the fake backend

Everything in S3 needs the domain enabled (0.5). The measurement in s3-14 also needs the
`IndexReaderStore.useReader` switch, which has no CLI hook yet: add one or flip it in the
debugger.

- [ ] **s3-1. list, open, save, rename** &mdash; **GUI** (a terminal can do list/open/rename; only Finder settles the presentation)

  ```
  sshdrive debug fake add nas --files 8
  ls -R ~/Library/CloudStorage/SSHDrive-nas/
  cat ~/Library/CloudStorage/SSHDrive-nas/Documents/Reports/report-000.txt
  printf 'x' >> ~/Library/CloudStorage/SSHDrive-nas/Documents/Reports/report-000.txt
  mv ~/Library/CloudStorage/SSHDrive-nas/Documents/Reports/report-000.txt \
     ~/Library/CloudStorage/SSHDrive-nas/Documents/Reports/renamed.txt
  sshdrive debug tree nas
  sshdrive debug index dump nas --table items --limit 40
  ```

  Expected: the four operations reach `enumerateItems`, `fetchContents`, `modifyItem` and
  `modifyItem` with `.filename` in `changedFields`, and the fake tree ends up matching.

  Result:

- [ ] **s3-2. Sidebar label and mount path, `nas` vs `SSH Drive - nas`** &mdash; **GUI**

  ```
  sshdrive debug fake add nas
  sshdrive debug fake add "SSH Drive - nas2"
  ls -la@ ~/Library/CloudStorage/
  ```

  Expected (section 2, section 3.1, section 4): the mount directory is derived by the
  system from the provider and the `displayName`. Record the exact directory name for both
  and what the Finder sidebar reads, so the sidebar never says "SSH Drive - SSH Drive -
  nas". This is what settles the naming scheme.

  Result:

- [ ] **s3-3. Does the system call `enumerateChanges` on a folder's enumerator when Finder shows it?** &mdash; **GUI**

  Open a folder in Finder, leave it, come back. Watch the extension's log for
  `enumerateChanges` on that container versus a fresh container enumerator.

  Expected: decides which of section 6.5's two fallbacks applies to the `viewed` reason.

  Result:

- [ ] **s3-4. What Finder does with `.filenameCollision`** &mdash; **GUI**

  Create a collision in the fake tree (`debug mutate nas create-file Documents/README.md`
  next to an existing `readme.md`), then look at the folder in Finder.

  Result:

- [ ] **s3-5. `fileSystemFlags.userExecutable` and `chmod +x`** &mdash; **VM** for the first half, **GUI** for the round trip

  ```
  sshdrive debug mutate nas chmod Documents/script.sh --mode 755
  ls -l ~/Library/CloudStorage/SSHDrive-nas/Documents/script.sh
  chmod +x ~/Library/CloudStorage/SSHDrive-nas/Documents/other.sh
  ```

  Expected (section 5.4): a served item with `userExecutable` materializes executable, and
  a `chmod +x` inside the mount arrives as `.fileSystemFlags` in `changedFields`.

  Result:

- [ ] **s3-6. The delete confirmation without `allowsTrashing`** &mdash; **GUI**

  Expected (section 5.4): no trash, so Finder should offer an immediate delete. Record the
  wording.

  Observation, 2026-09-04 (VM, no GUI needed for this half): `allowsTrashing` is not
  enough on its own. `NSFileProviderDomain.supportsSyncingTrash` defaults to **YES**, so
  the system draws its own `.Trash` in the mount at `add(domain)` time and then asks the
  extension to enumerate `NSFileProviderTrashContainerItemIdentifier`. Answering that with
  `noSuchItem` is what hung `ls -la`: the system reads it as "the container was deleted",
  tries to delete it, and retries about once a second for ever. The extension now fails
  that call with `NSCocoaErrorDomain` / `NSFeatureUnsupportedError` (3328), which is what
  `NSFileProviderReplicatedExtension.h` prescribes, and the agent adds every domain with
  `supportsSyncingTrash = false`. The system then drops the `.Trash` from the mount
  entirely after two throttled attempts, so `ls -la` returns in ~20 ms and shows no
  `.Trash`. Whatever Finder's confirmation wording turns out to be, it is asked about an
  item with no trash container behind it. See results.md, 2026-09-04.

  Result:

- [ ] **s3-7. `modifyItem` returning a version that differs from the upload** &mdash; **GUI**

  Expected (section 5.5): the system re-fetches and does not re-offer the same change. The
  conflict path depends on it.

  Result:

- [ ] **s3-8. Atomic saves from TextEdit, Xcode and Word** &mdash; **GUI**

  Expected: one `modifyItem` on the original identifier. A `createItem` + `deleteItem`
  pair loses a pin or a tag on that file, because there are no tombstones (section 5.3).
  Record each app separately.

  Result:

- [ ] **s3-9. `.syncAnchorExpired` from a working set whose `enumerateItems` returns nothing** &mdash; **GUI**

  ```
  sshdrive debug sweep nas off          # so the system's own behaviour is visible
  sshdrive debug anchor expire nas
  ```

  Expected (section 5.3): the system re-enumerates. Record exactly what it re-enumerates,
  and turn the sweep back on afterwards.

  Result:

- [ ] **s3-10. The read-only WAL reader from inside the sandbox** &mdash; **GUI** (needs the appex running)

  Expected (section 5.2): the extension opens `index.sqlite` read-only in WAL mode from the
  group container while the agent writes, including creating/opening the `-shm` sidecar for
  writing, which a read-only connection needs. A sandbox denial appears under
  `process == "sandboxd"`.

  Result:

- [ ] **s3-11. `meta.reconciling` and `meta.generation` change promptly** &mdash; **GUI**

  Result:

- [ ] **s3-12. A `sqlite3_backup_init` restore into the live file is visible to the open reader** &mdash; **GUI**

  Expected (section 5.3): visible; that is why the restore goes into the live database
  rather than replacing the file.

  Result:

- [ ] **s3-13. `item(for:)` throwing `.serverUnreachable`** &mdash; **GUI**

  Expected (section 5.2): harmless; the reconcile stall depends on it. Never
  `.noSuchItem`, which deletes the user's file.

  Result:

- [ ] **s3-14. Reader versus XPC round trip under a 50,000-entry listing** &mdash; **GUI**

  `sshdrive debug fake add big --files 50000`, then time `item(for:)` both ways by flipping
  `Apps/FileProvider/IndexReaderStore.useReader`.

  Expected: this measurement is what decides whether the read-only reader survives at all
  (section 12 milestone 1).

  Result:

Deferred to milestone 3 against a real server: replace an enumerated directory with a
symlink to `/etc` and confirm nothing inside is listed, fetched or deleted (section 9.1).

---

## S4 - eviction and access time

- [ ] **s4-1. Does `evictItem` work for files in our domain?** &mdash; **GUI**

  Materialize a file, then call `NSFileProviderManager.evictItem` from the agent (a
  `debug` hook will be needed; milestone 7 gives it a real command).

  Expected (section 7): yes for files. Folder eviction is known to fail and the loop skips
  directories.

  Result:

- [ ] **s4-2. Does atime advance on every read, only when older than mtime, or never?** &mdash; **GUI**

  ```
  stat -f '%a %m' ~/Library/CloudStorage/SSHDrive-nas/Documents/Reports/report-000.txt
  cat  ~/Library/CloudStorage/SSHDrive-nas/Documents/Reports/report-000.txt >/dev/null
  stat -f '%a %m' ~/Library/CloudStorage/SSHDrive-nas/Documents/Reports/report-000.txt
  ```

  Read with `AT_SYMLINK_NOFOLLOW`, as the loop does (section 9.1). Expected: one of the
  three. The answer decides which of the two meanings the TTL has, and `sshdrive show` and
  the docs must state the one in force.

  Result:

- [ ] **s4-3. Does the system refuse to evict an item with pending changes?** &mdash; **GUI**

  Expected (section 7 step 3): yes, so the eviction loop needs no pending-upload check of
  its own. If no, milestone 7 adds one.

  Result:

- [ ] **s4-4. Do Finder tags and other xattrs survive eviction?** &mdash; **GUI**

  Tag a materialized file, evict it, look again. Expected (section 5.4): they survive. If
  not, they have to be re-applied after every evict.

  Result:

- [ ] **s4-5. Does a launchd agent's `stat` under `~/Library/CloudStorage` draw a TCC prompt?** &mdash; **VM** (to see the `EPERM`), **GUI** (to see the prompt)

  From the launchd-started agent, `stat` a materialized file and record errno. Expected
  (section 7): a prompt a launchd agent cannot answer comes back as a silent `EPERM`, and
  the loop then runs on `last_fetch` alone and `sshdrive doctor` says so. Test on 14 and
  15, which is where the design says the behaviour is uncertain.

  Result:

---

## S6 - pinning through `contentPolicy`

Every S6 sub-question needs the domain enabled (0.5), and the menu ones need Finder.

- [ ] **s6-1. Does an eager policy download the whole subtree after a working-set signal?** &mdash; **GUI**

  ```
  sshdrive debug policy nas Documents/Reports eager-keep
  sshdrive debug index dump nas --table items --limit 40      # kept and the bitmasks
  ```

  Expected (section 7.1 step 2): the system re-reads the rows whose metadata version moved
  and downloads the subtree through our normal `fetchContents`.

  Result:

- [ ] **s6-2. Does it enumerate subfolders never opened in Finder?** &mdash; **GUI**

  Expected: yes. The offline claim in section 7.1 depends on it.

  Result:

- [ ] **s6-3. Does it accept a chain of never-enumerated ancestors reported through the working set?** &mdash; **GUI**

  Pin a path that Finder has never shown. Expected: `sshdrive pin` on an unseen path
  depends on this (section 7.1 step 1).

  Result:

- [ ] **s6-4. Do new remote files under a pin get fetched on the next poll?** &mdash; **GUI**

  ```
  sshdrive debug mutate nas create-file Documents/Reports/new.txt --contents hello
  ```

  Result:

- [ ] **s6-5. Does `evictItem` refuse a kept item?** &mdash; **GUI**

  Expected (section 7.2): yes; and an eviction that reaches one anyway is re-asserted, not
  read as an unpin.

  Result:

- [ ] **s6-6. Does an explicit `.downloadLazily` on a child override an eager ancestor?** &mdash; **GUI**

  ```
  sshdrive debug policy nas Documents/Reports/big eager-keep
  sshdrive debug policy nas Documents/Reports/big/scratch lazy
  ```

  Expected (section 7.1.1): yes; exclusions depend on it.

  Result:

- [ ] **s6-7. Which built-in menu items Finder shows for pinned versus unpinned items** &mdash; **GUI**

  Expected (section 7.2): an item returned without `allowsEvicting` gets no "Remove
  Download" entry. Record every entry for both states, and confirm no other route evicts a
  kept item (drag out, "Optimise Storage", the Storage pane).

  Result:

- [ ] **s6-8. Do our custom actions appear at the top level of the context menu or in a submenu?** &mdash; **GUI**

  The two actions and their `userInfo.kept` activation rules are already declared in
  `Apps/FileProvider/Info.plist`; `performAction` is milestone 8.
  `fileproviderctl evaluate <item>` prints what the system thinks applies, which is worth
  recording next to what Finder actually draws.

  Result:

- [ ] **s6-9. Does an eager policy on `.rootContainer` download the whole location?** &mdash; **GUI**

  ```
  sshdrive debug policy nas / eager-keep
  ```

  Expected (section 7.1.2): the root is not a special case.

  Result:

- [ ] **s6-10. Do the custom actions appear on the window background and the sidebar entry, with the root as the selected item?** &mdash; **GUI**

  Result:

- [ ] **s6-11. How many `fetchContents` calls the system keeps open at once for an eager subtree** &mdash; **GUI**

  Count concurrent transfers in the agent's log. Expected: this bounds the transfer
  scheduler's backlog (section 6.2).

  Result:

- [ ] **s6-12. `contentPolicy = .inherited` as the neutral value for an unpinned item** &mdash; **GUI**

  Expected (skeleton-notes item 10): `.inherited` behaves as "no opinion" and does not
  force a download.

  Result:
