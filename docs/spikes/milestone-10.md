# Milestone 10 spike: ship

Runbook for DESIGN.md section 12 milestone 10 - the Developer ID release, notarization,
the DMG, the Homebrew cask, `sshdrive logs`, the docs - and for spike **S9**, whose answer
decides what `sshdrive set nickname` does. Each section has the steps, what the design
expects, and a **Result** line for what actually happened. The long-form entry is in
`results.md` under "2026-09-05 (milestone 10)".

| Tag | Meaning |
|---|---|
| **linux** | this development box. No Swift, no `codesign`, no `hdiutil`, no Homebrew. |
| **unit** | a package test (`swift test`). |
| **VM** | the headless Mac at `alec@100.114.204.5`, macOS 26.4.1, Xcode 26.4. |
| **mount** | needs the release build installed on the VM and a real File Provider domain. |

Everything below ran on 2026-09-05.

---

## 0. Setup

### 0.1 The Apple material on the VM

```
~/Developer/SSH_Drive.provisionprofile                     development, org.shirls.sshdrive
~/Developer/SSH_Drive_FileProvider_Testing.provisionprofile  development, the appex
~/Developer/SSH_Drive_Developer_ID.provisionprofile        Developer ID, org.shirls.sshdrive
~/Developer/AuthKey_7Q847UP2Z3.p8                          App Store Connect API key
login keychain: "Apple Development: … (73XULXLK48)"        C50D92F1…C13
                "Developer ID Application: … (RWGDZAYBM8)" 6C055553…D05
```

The `.p8` stays on the VM. `scripts/release.sh` passes its path to `notarytool` and never
reads it; nothing copies it into the repo, the bundle or the DMG.

### 0.2 `swift test` (unit)

```sh
scripts/mac-build.sh test
```

**Result: 606 tests, 0 failures, 40 skipped** (592 before this milestone). The new ones are
ten in `LoggingTests/LogQueryTests` (the `sshdrive logs` predicate), two in
`ConfigTests/AddArgumentsTests` for the nickname flow S9 settled, and three in
`SSHProcessTests/OptionAssemblyTests` for the orphan sweep's new kill.

---

## 1. `scripts/release.sh` (VM)

```sh
scripts/release.sh build     # Release, Developer ID signed, hardened runtime
scripts/release.sh dmg       # + SSH-Drive-0.1.0.dmg
NOTARY_KEY_ID=7Q847UP2Z3 NOTARY_ISSUER=<issuer> scripts/release.sh notarize
```

What it does differently from `mac-build.sh signed`: Release rather than Debug, the
Developer ID identity by SHA-1 rather than the Apple Development one by name, a real
`--timestamp` (notarization refuses a signature without one), and the appex's *release*
entitlements - sandbox and app group only, no
`com.apple.developer.fileprovider.testing-mode` and no embedded profile of its own.

**Result: builds, signs and verifies.**

```
Identifier=org.shirls.sshdrive
Authority=Developer ID Application: Alec Woodward-Mitchell (RWGDZAYBM8)
Authority=Developer ID Certification Authority
Authority=Apple Root CA
Timestamp=5 Sep 2026 at 3:19:04 am
Runtime Version=26.4.0
codesign --verify --deep --strict: (no output; valid)
spctl --assess: rejected / source=Unnotarized Developer ID     <- expected, pre-notarization
```

---

## 2. The failure that cost the most: the profile names the wrong certificate

The first Developer ID build embedded `~/Developer/SSH_Drive_Developer_ID.provisionprofile`
and kept `keychain-access-groups`, as section 3.1 wants. It signed, verified, **notarized
and stapled**, `spctl` said `accepted / source=Notarized Developer ID` - and then would not
launch.

```
$ SSHDRIVE_AGENT_ROLE=unregister "/Applications/SSH Drive.app/Contents/MacOS/SSH Drive"
rc=137                                                # 128 + SIGKILL
$ open -g "/Applications/SSH Drive.app"
The application cannot be opened for an unexpected reason,
  error=Error Domain=RBSRequestErrorDomain Code=5 "Launch failed."
  NSUnderlyingError=… Code=163 … {NSLocalizedDescription=Launchd job spawn failed}
```

The log says why:

```
taskgated-helper  Checking profile: SSH Drive Developer ID
taskgated-helper  org.shirls.sshdrive: Unsatisfied entitlements: keychain-access-groups
taskgated-helper  Disallowing: org.shirls.sshdrive
amfid             /Applications/SSH Drive.app/Contents/MacOS/SSH Drive not valid:
                  AppleMobileFileIntegrityError Code=-413 "No matching profile found"
kernel (AMFI)     Code has restricted entitlements, but the validation of its code
                  signature failed. Unsatisfied Entitlements: keychain-access-groups
```

The profile *does* grant it - `keychain-access-groups => ["RWGDZAYBM8.*"]`, identical to
the development profile's. What differs is the certificate:

| | profile's `DeveloperCertificates` | login keychain |
|---|---|---|
| development | `C50D92F1…C13` Apple Development | the same, **matches** |
| Developer ID | `D853BADB…F6` Developer ID Application | `6C055553…D05`, **does not match** |

The account holds two Developer ID Application certificates (`BNRD3V55JA` = `D853BADB…`,
`T9DF89U2YU` = `6C055553…`, both issued 2027-02-01) and the profile was created against the
one whose private key is not on this Mac.

Three things were tried and recorded:

- **Adding `com.apple.application-identifier` and `com.apple.developer.team-identifier`**
  to the signed entitlements, to "match the profile properly": worse, not better -
  `Unsatisfied entitlements: com.apple.developer.team-identifier, keychain-access-groups`.
  A profile whose certificate does not match is not partially applicable, it is not
  applicable, and every restricted entitlement in the bundle becomes unsatisfied. (It is
  also the key S1 a1 found makes AMFI refuse to let *launchd* start the agent at all.)
- **The control**: the same Release binary, the same entitlements file, signed with the
  Apple Development identity and the development profile - `rc=0`, launches, keychain
  reachable. So nothing about Release, Developer ID or the hardened runtime is the problem.
- **Creating the right profile from the App Store Connect API key**: the key reads fine
  (`GET /v1/certificates`, `GET /v1/bundleIds` both 200) but `POST /v1/profiles` returns
  `403 FORBIDDEN_ERROR`. A notarization-grade key cannot create a provisioning profile;
  that stays a web-UI job for the account owner.

**Result: `scripts/release.sh` now checks the profile's `DeveloperCertificates` against the
signing identity before signing**, and when they do not intersect it drops
`keychain-access-groups`, prints both hashes and what to do, and carries on:

```
	WARNING -------------------------------------------------------
	/Users/alec/Developer/SSH_Drive_Developer_ID.provisionprofile does not authorise the signing identity.
	  signing certificate: 6C055553C6A361398A3CC48654E1FADC14660D05
	  profile certificates: D853BADB70715CDE1F3F7A4435B45F1AB45667F6
	Re-create the Developer ID profile at developer.apple.com for
	org.shirls.sshdrive, selecting the certificate above. …
	Signing WITHOUT keychain-access-groups. The build runs, mounts and
	syncs; it cannot reach the keychain, so no stored password or key
	passphrase is usable (DESIGN.md section 3.1).
	---------------------------------------------------------------
```

The shipped state of this milestone is therefore a **notarized Developer ID build without
keychain access**. Everything else works; `sshdrive doctor` says `[ fail ] keychain … A
required entitlement isn't present`. **What the owner has to do: re-create the Developer ID
provisioning profile for `org.shirls.sshdrive` selecting certificate `T9DF89U2YU`
(`6C055553…D05`), put it at `~/Developer/SSH_Drive_Developer_ID.provisionprofile`, and
re-run `scripts/release.sh`.** No code change is needed; the guard will embed it and keep
the entitlement.

---

## 3. Notarization (VM)

Section 10's plan was a `notarytool` keychain profile named `sshdrive-notary`.

**Result: `xcrun notarytool store-credentials` cannot be run over ssh.** It writes to the
login keychain through an interactive authorisation and fails with `User interaction is not
allowed` even with the keychain explicitly unlocked. A headless release therefore uses an
**App Store Connect API key**:

```sh
xcrun notarytool submit … --key ~/Developer/AuthKey_7Q847UP2Z3.p8 \
    --key-id 7Q847UP2Z3 --issuer <issuer-uuid> --wait
```

`scripts/release.sh` prefers that route (`NOTARY_KEY`, `NOTARY_KEY_ID`, `NOTARY_ISSUER`,
with `NOTARY_KEY` defaulting to the single `~/Developer/AuthKey_*.p8`), falls back to
`--keychain-profile` when the variables are unset and the profile exists, and otherwise
prints both recipes and **stops cleanly after the DMG without failing the run**.

**Result: Accepted, twice per release.** The app is submitted and stapled first, then the
DMG is rebuilt around the stapled app and notarized in its own right - stapling a DMG
staples the image, not the app inside it.

```
id: 8ceecf10-be1e-4a10-b3f4-dd5d7ff2a327   SSH-Drive-app.zip   status: Accepted
id: 7a06842c-e6d5-48cb-986c-9bcfd0438995   SSH-Drive-0.1.0.dmg status: Accepted
xcrun notarytool log 7a06842c-…:
  "status": "Accepted", "statusSummary": "Ready for distribution",
  "statusCode": 0, "issues": null, 17 ticketContents entries
    (each of SSH Drive.app, sshdrive, sshdrive-askpass, SSHDriveFileProvider.appex,
     x86_64 and arm64, plus the DMG itself)
The staple and validate action worked!
spctl --assess --type execute: accepted / source=Notarized Developer ID
```

Notarization said nothing about the broken provisioning profile. It does not look at
profiles at all, which is exactly why section 2's failure is worth its own section: a build
can be perfectly notarized and still be killed at exec.

---

## 4. The DMG (VM)

```sh
hdiutil create -volname "SSH Drive" -srcfolder <staging> -fs HFS+ -format UDZO \
    -imagekey zlib-level=9 dist/SSH-Drive-0.1.0.dmg
```

Staging is `SSH Drive.app` plus a symlink named `Applications` → `/Applications`.

**Result: about 7.6 MB, `hdiutil verify` VALID, mounts with both entries.**

```
$ ls -la "/Volumes/SSH Drive/"
lrwxr-xr-x  Applications -> /Applications
drwxr-xr-x  SSH Drive.app
```

No AppleScript window dressing: a headless VM has no Finder to lay icons out with.

**The disk image is signed as well as stapled, and it has to be.** A DMG carrying a
notarization ticket but no signature of its own is refused on the download path:

```
$ xcrun stapler validate dist/SSH-Drive-0.1.0.dmg
The validate action worked!
$ codesign -dvv dist/SSH-Drive-0.1.0.dmg
dist/SSH-Drive-0.1.0.dmg: code object is not signed at all
$ spctl --assess --type open --context context:primary-signature -v dist/SSH-Drive-0.1.0.dmg
dist/SSH-Drive-0.1.0.dmg: rejected
source=no usable signature
```

Homebrew never sees that - it reads the app out of the image - but a person who
double-clicks the download does. `release.sh` now `codesign`s the image with the same
Developer ID identity before submitting it, and the finished artefact assesses:

```
dist/SSH-Drive-0.1.0.dmg: accepted
source=Notarized Developer ID
```

---

## 5. `sshdrive logs` (unit + VM)

`LogQuery` in `Logging` builds the predicate; the CLI `execv`s `/usr/bin/log`.

```
sshdrive logs                      subsystem == 'org.shirls.sshdrive'
                                   OR (process == 'fileproviderd'
                                       AND eventMessage CONTAINS 'org.shirls.sshdrive')
sshdrive logs nas                  (ours AND (CONTAINS[c] '<domain-uuid>' OR CONTAINS[c] 'nas'))
                                   OR (fileproviderd AND CONTAINS[c] '<domain-uuid>')
```

Why fileproviderd is in it: everything the *system* decides about a domain - the
enumerations it asks for, what it made of an answer, `FP -2011`, the disconnection states -
is logged under Apple's subsystem and never reaches ours. Every File Provider diagnosis in
this directory was made by reading the two side by side.

Why a named query matches two strings: our own lines carry the location's UUID in most
places and its display name in the ones written for a person; fileproviderd knows only the
identifier.

`--info` is always passed, because `log show` hides the info level and most of the
transport's detail is `Log.ssh.info`. `/usr/bin/log` is spelled absolutely, because zsh has
a `log` builtin that shadows it.

**Result: nine unit tests, and on the VM the predicate returns both halves** - our
`[org.shirls.sshdrive:agent]` lines and fileproviderd's lines for the domain. `--follow`
streams and Ctrl-C ends it, because the CLI `exec`s rather than piping.

---

## 6. Spike S9: does `add(domain)` rename in place? (mount)

The question section 11 asks: does `NSFileProviderManager.add(domain)` with an existing
identifier and a new `displayName` rename the domain in place, keeping cache and pending
uploads?

Setup on a real mount of `alec@192.168.64.1:2201` (`deb`, key auth, no keychain needed):

```sh
sshdrive add s9 alec@192.168.64.1:2201 --identity ~/.ssh/sshdrive-spike --no-password
ssh … "mkdir -p ~/m10 && echo original-content > ~/m10/keep.txt && echo edit-me > ~/m10/edit.txt"
sshdrive debug watch s9 --full          # 2 changed, 3 listed
cat ~/Library/CloudStorage/SSHDrive-s9/m10/{keep,edit}.txt      # materialize both
sshdrive debug fault s9 --writes on     # every modifyItem answers .serverUnreachable
pkill -9 -f sshdrive-d8f9449c           # and kill the master under it
echo "PENDING WHILE MASTER DEAD …" > …/m10/edit.txt
```

State before the rename: **4 materialized** (`""`, `m10`, `m10/edit.txt`, `m10/keep.txt`),
**1 pending** (`m10/edit.txt`), the mount at `~/Library/CloudStorage/SSHDrive-s9`, and the
server still holding the old bytes.

One note on making a pending write: killing the master alone is not enough. The first
attempt wrote through - the agent reconnects on the breaker's backoff unprompted (S5), and
the write reached the server before the failure could be observed. `debug fault --writes
on` is what holds the write in the system's pending set.

Then:

```sh
sshdrive debug domain rename s9 s9-renamed     # one add(domain), same identifier
```

**Result: S9 is YES.**

```
domainsBefore: ["s9 (D8F9449C-1BD6-44C5-87C3-7345E303107A)"]
domainsAfter:  ["s9-renamed (D8F9449C-1BD6-44C5-87C3-7345E303107A)"]

~/Library/CloudStorage/SSHDrive-s9         gone
~/Library/CloudStorage/SSHDrive-s9-renamed present, same inode contents
materialized 4 ['', 'm10', 'm10/edit.txt', 'm10/keep.txt']      unchanged
pending      1 ['m10/edit.txt']                                 unchanged
cat …/SSHDrive-s9-renamed/m10/edit.txt  -> the pending local bytes
cat …/SSHDrive-s9-renamed/m10/keep.txt  -> original-content, no re-fetch
debug stat s9 m10/keep.txt -> dataless: false, indexLastFetch unchanged
```

and afterwards the pending write still flushes:

```sh
sshdrive debug fault s9 --writes off
sshdrive debug signal s9 --error-resolved
# server now has "PENDING WHILE MASTER DEAD …";  pending 0
```

The system renamed the mount directory itself and carried the replica across. Nothing was
re-fetched, nothing was re-created, and the upload it was holding was still its own upload
afterwards.

**So `sshdrive set <name> nickname` renames in place.** `LocationSettingKey.nickname` is no
longer `recreatesDomain`; it is `renamesDomainInPlace`, the domain is *not* removed first
(removing it is precisely what would throw the replica away), the pending-uploads refusal
is gone and so is the "the cache is dropped" warning. Section 13's data-loss caveat on
nickname is removed and replaced with a dated entry.

---

## 7. `agent stop` and the orphan sweep (mount)

Milestone 7/8 noticed that `sshdrive agent stop` exits 0.2 s after replying and leaves
every location's `ssh -N` master running: the next start's sweep unlinks the stale socket
but has no pid to kill, so the old `ssh` holds a connection open for ever against a socket
that no longer exists. Four install cycles out of four left one behind.

Both halves are fixed:

- `DomainManager.shutdownAll()` stops every detector, evictor, gate and transport before
  the process exits, concurrently, with a 20 s backstop so an unreachable server cannot
  hold the exit open. The reply is sent first, because the CLI is waiting on it.
- `ControlSocket.sweepOrphans` now asks `ssh -O check` for the owner's pid before `-O
  exit`, and if that process is still alive afterwards it gets TERM and then KILL. The pid
  is checked to still be a process named `ssh` first (`KERN_PROC_PID`), because a pid read
  from a socket left behind by an earlier boot can have been reused by anything.
- The agent handles **SIGTERM** itself and exits 0 through the same shutdown. It had no
  handler at all before, and the default disposition is death by signal, which launchd
  reads as an unsuccessful exit and restarts at once - out of a bundle that, mid-upgrade,
  is the old one about to be deleted. Section 10 says "the agent exits with status 0 on
  TERM"; now it does.

**Result: a TERM took the agent and all four of the location's `ssh` processes down**, and
`launchctl list` showed `-	0	org.shirls.sshdrive.agent` - down, exit status 0, not
restarted.

**And a third fix was needed.** A clean `agent stop` still left **two** `ssh -N` masters
alive - with **no socket at all**, so neither the sweep nor `-O exit` could ever reach
them. A location that has been restarted can hold two masters (the second finds the first's
socket in place, prints "ControlSocket already exists, disabling multiplexing" and runs
without one), and `SSHMaster.shutdown()` unlinks the path on its way out. So
`ControlSocket.killStrayMasters()` goes in by the command line instead: a process named
`ssh`, owned by this uid, whose argv contains `ControlPath=$TMPDIR/sshdrive-`. `$TMPDIR` is
per-user and per-boot and nothing else writes that option, so it cannot reach a terminal's
own `ssh`. It runs at the agent's start, before any connection, and at its exit, after
every transport is down - and nowhere else.

After the fix, `agent stop` with a live location left `0` matching processes and no socket
in `$TMPDIR`.

---

## 8. The upgrade path (VM, mount)

Simulated exactly as `brew upgrade` does it, over a running install with a real location,
four materialized items and an upload the system was holding:

```sh
kill -TERM <agent>                       # the cask's uninstall stanza, by launchd label
rm -rf "/Applications/SSH Drive.app"     # Homebrew deletes, then installs
hdiutil attach …; ditto "/Volumes/SSH Drive/SSH Drive.app" "/Applications/SSH Drive.app"
SSHDRIVE_AGENT_ROLE=unregister "/Applications/SSH Drive.app/Contents/MacOS/SSH Drive"
open -g "/Applications/SSH Drive.app"    # the postflight, in that order
```

**Result: the login item comes back with no logout, and nothing is lost.**

```
old inode 56733069  ->  new inode 56743589
unregister rc=0     open rc=0
launchctl print: state = running, runs = 1, last exit code = (never exited)
doctor: green apart from the keychain line and the CLI-on-PATH warning
file provider domains: s9 (D8F9449C-…)          the domain is back
materialized: the tree is still cached, keep.txt still dataless=false
the held upload reached the server
```

The vnode watch fired on the way - `my own executable was replaced; waiting for the new
bundle` - and the TERM that `SMAppService.unregister()` sends to the running job is what
actually took the old agent down, through the new handler, with its masters.

**Two things section 10 did not have, both found here.**

*The unregister has to wait for launchd to drop the job.* Run back to back, the first
attempt failed: `unregister()` returned and `SMAppService.status` said `notRegistered`
while launchd was still spawning the old record, the very next spawn died
`EXC_CRASH (SIGKILL (Code Signature Invalid))` / `"indicator":"Launch Constraint
Violation"`, and the `register()`200 ms later left the job carrying the *previous* bundle's
launch constraint:

```
launchctl print: runs = 10, last exit code = 78: EX_CONFIG, job state = spawn failed
launchd: Service only ran for 0 seconds. Pushing respawn out by 10 seconds.
```

for ever, with the mach service accepting connections and answering nothing (`doctor` says
"accepted the connection but not the command in time", which is the right sentence for a
wrong situation). The same three commands with five seconds between them worked first time.
The `unregister` role now polls `launchctl print` until the service is gone before it
exits, so the cask's postflight is safe as written.

*A pending upload survives the replacement and can be re-offered afterwards.* The system
handed the same `modifyItem` to the new extension instance, by which time the bytes were
already on the server, and section 5.5's conflict check did exactly its job:

```
modifyItem m10/edit.txt changedFields=0x81
conflict on m10/edit.txt: base 56-1788543692-0, server 51-1788543920-0
conflict copy m10/edit (conflicted copy from chosen-newt …).txt kept the local content
evicted 75775610-… after a conflict copy on attempt 1
```

Nothing was lost; the same write simply arrived twice, and the conflict machinery is what
makes that safe.

Also found here: `add(domain)` can report `NSCocoaErrorDomain 4099` *"connection to service
named com.apple.FileProvider was invalidated"* **after the call has landed**. `addDomain`
now re-reads `NSFileProviderManager.domains()` before believing the error.

---

## 9. The fresh-user install, quarantined (VM, `sshtest`)

The second local account `sshtest` (uid 502, admin, no sudo, console login by fast user
switching so `gui/502` exists), with the notarized DMG copied to `~sshtest/Downloads` and
quarantined the way a browser sets it:

```sh
xattr -w com.apple.quarantine "0083;<hex-time>;Safari;<uuid>" ~/Downloads/SSH-Drive-0.1.0.dmg
spctl --assess --type open --context context:primary-signature --verbose=4 <the dmg>
hdiutil attach …; ditto "/Volumes/SSH Drive/SSH Drive.app" "/Applications/SSH Drive.app"
xattr -w -r com.apple.quarantine "0083;…;Safari;<uuid>" "/Applications/SSH Drive.app"
spctl --assess --type execute --verbose=4 "/Applications/SSH Drive.app"
SSHDRIVE_AGENT_ROLE=unregister … ; open -g "/Applications/SSH Drive.app"
```

**Result: both accepted, and the install needs no visit to System Settings.**

```
the quarantined DMG:     accepted / source=Notarized Developer ID
the quarantined bundle:  accepted / source=Notarized Developer ID
unregister rc=0   open rc=0
launchctl print gui/502/…: state = running, runs = 1, last exit code = (never exited)
the com.apple.quarantine xattr is still on the bundle afterwards
doctor: green apart from [ fail ] keychain and the CLI-on-PATH warning
file provider domains: none;  no locations
```

This is the half of S1(f3) that 2026-09-04 could not do: that pass installed by `rsync`,
so the bundle carried no quarantine xattr at all and said nothing about Gatekeeper. It now
says something: a **notarized and stapled** build opens with `open -g` returning 0 and no
dialog to answer, from a quarantined bundle, on an account that has never opened System
Settings. The one-time "downloaded from the Internet" dialog belongs to a Finder
double-click, which a headless VM cannot produce; `open -g` from a script does not raise it.

The pre-notarization state, for contrast, was recorded twice in this pass: `spctl --assess`
on the freshly Developer ID-signed app before submission says
`rejected / source=Unnotarized Developer ID`, and an ad-hoc re-signed copy of the same
notarized bundle says `rejected` outright.

**And the stranded-domain cleanup was proved here.** `sshtest` still had the fake `nas`
domain and its group container from the 2026-09-04 pass. Deleting `config.json` and
starting the new agent removed the domain and its `~/Library/CloudStorage/SSHDrive-nas`
directory by itself - which is section 10's "the app on its first launch removes every
domain whose identifier is not in `config.json`, or every domain of ours when the container
is gone too", and nothing implemented it until now. `zap` runs after Homebrew has deleted
the app, so this is the only place that debt can be paid.

`sshtest` was left clean afterwards: agent stopped, login item unregistered, the app
removed, the group container and the download deleted, no CloudStorage entries, no
processes.

---

## 10. The Homebrew cask (linux)

`packaging/homebrew-tap/Casks/ssh-drive.rb`, staged here because the tap must be a
repository of its own (`alecdwm/homebrew-tap`, which does not exist yet);
`packaging/homebrew-tap/README.md` says where it goes.

The filename is `ssh-drive.rb`, not `sshdrive.rb`: Homebrew resolves
`brew install --cask ssh-drive` to `Casks/ssh-drive.rb`, so the basename *is* the token and
a mismatch is not installable. Sections 3.1 and 10.1 both name the cask `ssh-drive`. The
binary it symlinks is `sshdrive`, with no hyphen; the two names are different on purpose.

What it carries, and why:

| Stanza | Value |
|---|---|
| `url` | `…/releases/download/v#{version}/SSH-Drive-#{version}.dmg` + `sha256` |
| `depends_on` | `macos: ">= :sonoma"` (section 2's minimum 14) |
| `app` | `SSH Drive.app` |
| `binary` | `#{appdir}/SSH Drive.app/Contents/MacOS/sshdrive` |
| `postflight` | `SSHDRIVE_AGENT_ROLE=unregister` on the app's own executable, then `open -g` |
| `uninstall` | `signal: ["TERM", "org.shirls.sshdrive.agent"]` and **nothing else** |
| `zap` | `launchctl:` the same label, `trash:` the group container and the caches |
| `caveats` | the Local Network prompt, the background-item notification, `remove --all` |

The `signal:` label is the launchd label of section 3.1 and not the bundle id, because
Homebrew matches the string against `launchctl list` output where only the label appears
(S1 g1). `uninstall` deliberately has no `launchctl:` - Homebrew runs `uninstall` on
`brew upgrade` too, and booting the label out of launchd while `SMAppService` still
considers the item enabled leaves the mach service dead until the next login. `zap` does
have it, because nothing is coming back.

Two things `zap` **cannot** do, both said in `caveats` and by `sshdrive doctor`:

- **the keychain items.** They are in the data-protection keychain under access group
  `RWGDZAYBM8.org.shirls.sshdrive`; no file removal reaches them and no cask directive
  addresses them. Only `sshdrive remove --all` deletes them, and by the time `zap` runs the
  app is already gone.
- **the File Provider domains**, and so the sidebar entries and the cached content under
  `~/Library/CloudStorage`. Deleting those directories from a cask would throw away any
  upload the system still had pending, so they are left alone.

**Result: `brew style` and `brew audit` could not be run - there is no Homebrew on the
Linux box and none on the VM.** `ruby -c` on the VM (ruby 2.6.10, `/usr/bin/ruby`) is the
check that was available: `Syntax OK` (ruby 2.6.10p210, `/usr/bin/ruby`).

---

## 11. Noticed in passing

**`sshdrive remove --all` against a cold agent leaves the helper on the server.** The
removal is guarded by the location's `ChangeDetector` being up, and after an `agent stop`
the next CLI command is what starts the agent again - so a `remove --all` issued
immediately can arrive first and `~/.cache/sshdrive/sshdrive-helper-*` is left behind.
With the agent already running it removes the binary and the directory, as section 8 says.
Seen once, cleaned by hand; the fix belongs with milestone 9's cleanup path.

---

## 12. Teardown

**On the VM (`alec`):** no locations, no File Provider domains, no `~/Library/CloudStorage`
entries, no `ssh` processes and no `sshdrive-*` control socket in `$TMPDIR`; `/tmp/m10`,
`/tmp/sshdrive-release` and `/tmp/sshdrive-dmg` removed. The **notarized Developer ID
Release build is installed at `/Applications/SSH Drive.app`** and the agent is running:

```
Identifier=org.shirls.sshdrive
Authority=Developer ID Application: Alec Woodward-Mitchell (RWGDZAYBM8)
spctl --assess: accepted / source=Notarized Developer ID
stapler validate: The validate action worked!
launchctl list: <pid>  0  org.shirls.sshdrive.agent
dist/SSH-Drive-0.1.0.dmg  +  .sha256
```

`sshdrive doctor` is green apart from the two expected lines: `[ warn ] CLI on PATH` (the
cask is what symlinks it) and `[ fail ] keychain` (the provisioning-profile certificate
mismatch of section 2).

**On the servers:** `~/m10` removed from `deb`, and `~/.cache/sshdrive` is empty -
`sshdrive remove --all` took the helper off the server on the location's last connection,
as section 8 says it should.

**On `sshtest`:** nothing left. No app, no group container, no domains, no download, no
processes, login item unregistered.
