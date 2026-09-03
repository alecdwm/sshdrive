# Spike results

One entry per sub-question, newest date first. Steps and expected answers are in
`milestone-1.md`; this file records only what happened.

---

## 2026-09-04 - S1(e) on a fresh user install (sshtest)

The question section 0.5 left open: does a clean user, who has never opened System
Settings, have to flip **Login Items & Extensions > File Providers > SSH Drive** before a
freshly added domain works, or is `open -g` from the cask's `postflight` (section 10)
enough on its own?

**Answer: `open -g` alone is enough. No switch. The domain comes up enabled, the appex is
launched, and the mount lists.**

Machine: the same Mac, second local account `sshtest` (uid 502, admin, no sudo), created
for this and logged in at the console by fast user switching so `gui/502` exists. Nothing
in `alec`'s session, domains or login items was touched. The bundle under test is the one
already at `/Applications/SSH Drive.app` - the post-cask state, Debug, signed
`Apple Development: ... (73XULXLK48)`, Team `RWGDZAYBM8`, hardened runtime, with the
embedded profiles; it was not rebuilt or reinstalled for this pass. macOS 26.4.1
(25E253).

### Baseline, before anything ran

```
$ ls -la ~/Library/CloudStorage
ls: /Users/sshtest/Library/CloudStorage: No such file or directory
$ launchctl print gui/502/org.shirls.sshdrive.agent
Could not find service "org.shirls.sshdrive.agent" in domain for user gui: 502
$ pluginkit -m -A -i org.shirls.sshdrive.fileprovider -vvv
  (no matches)
$ pluginkit -m -v -p com.apple.fileprovider-nonui       # 3 plug-ins, all Apple's
$ fileproviderctl dump | grep -E 'domain:|user-disabled'
domain: (default)
domain: (default) (hidden)
$ ps -o pid,uid,user,args -p 84172
84172 501 alec Contents/MacOS/SSH Drive                 # alec's agent, left alone
```

Two baseline notes:

- **The group container already existed**, empty:
  `~/Library/Group Containers/RWGDZAYBM8.org.shirls.sshdrive/` with only
  `Library/{Application Support,Preferences,Caches,Application Scripts}` and
  `.com.apple.containermanagerd.metadata.plist`, all stamped 02:20, the same minute as
  the sixty-odd Apple group containers. `containermanagerd` creates the skeleton for
  every installed app's group at first login, before our code has ever run. So "no group
  container" is *not* a usable check for "the app has never run here"; `config.json`
  inside it is.
- **`sfltool dumpbtm` needs admin rights and is unusable over ssh**:
  `Error obtaining right system.privilege.admin: ... errAuthorizationInteractionNotAllowed`.
  The background-task database could not be read directly at any point in this pass;
  everything below is inferred from `launchctl`, `pluginkit`, `fileproviderctl` and
  fileproviderd's log, which agree.

### The section 10 postflight, run exactly as written

The bundle carries **no `com.apple.quarantine` xattr** (`xattr -l` prints nothing) because
it was installed by `rsync`, not by a cask download - so this pass says nothing about
Gatekeeper's one-time dialog.

```
$ open -g "/Applications/SSH Drive.app"
open rc=0
```

`open` returns 0 on an `.app` whose main executable is not an `NSApplication`
(skeleton-notes item 5), as S1(e1) expected. Ten seconds later:

```
$ launchctl print gui/502/org.shirls.sshdrive.agent
gui/502/org.shirls.sshdrive.agent = {
	active count = 2
	path = (submitted by smd.91)
	type = Submitted
	managed_by = com.apple.xpc.ServiceManagement
	state = running
	program identifier = Contents/MacOS/SSH Drive (mode: 2)
	parent bundle identifier = org.shirls.sshdrive
	parent bundle version = 1
	BTM uuid = F6AAF5E2-FD05-4FD2-981D-A0698D45DB38
	environment = { OSLogRateLimit => 64
	                SSHDRIVE_AGENT_ROLE => launchd
	                XPC_SERVICE_NAME => org.shirls.sshdrive.agent }
	domain = gui/502 [100279]
	runs = 1
	pid = 84448
	...
	semaphores = { successful exit => 0 }
	endpoints = { "RWGDZAYBM8.org.shirls.sshdrive.agent" = { active = 1 ... } }
	properties = partial import | runatload | resolve program | has LWCR
}
$ ps -o pid,uid,user,args -p 84448
84448 502 sshtest Contents/MacOS/SSH Drive
```

`runatload`, `SuccessfulExit = 0`, the group-prefixed mach endpoint, and the agent running
as 502 in its own GUI domain - the whole of e1, from one `open -g`, on a user who has
opened nothing.

```
$ pluginkit -m -A -i org.shirls.sshdrive.fileprovider -vvv
     org.shirls.sshdrive.fileprovider(0.1.0)
	            Path = /Applications/SSH Drive.app/Contents/PlugIns/SSHDriveFileProvider.appex
	            UUID = 55C4395C-E92A-4ECC-9A14-624CC2746CBD
	       Timestamp = 2026-09-03 16:28:26 +0000       # = 02:28 local, our open -g
	             SDK = com.apple.fileprovider-nonui
	   Parent Bundle = /Applications/SSH Drive.app
 (1 plug-in)
```

One registration, under `/Applications`, timestamped by this `open -g`. That is e2.

```
$ "/Applications/SSH Drive.app/Contents/MacOS/sshdrive" doctor
[  ok  ] agent reachable            the background agent answered
[ warn ] CLI on PATH                sshdrive is not on PATH; the Homebrew cask symlinks it for you
[  ok  ] app in /Applications       /Applications/SSH Drive.app
[  ok  ] macOS version              26.4.1
[  ok  ] login item                 enabled
[  ok  ] app group container        /Users/sshtest/Library/Group Containers/RWGDZAYBM8.org.shirls.sshdrive
[  ok  ] extension registered       org.shirls.sshdrive.fileprovider(0.1.0)
[  ok  ] ssh                        OpenSSH_10.2p1, LibreSSL 3.3.6
[ warn ] login shell snapshot       not taken: the snapshot arrives in milestone 2 with the transport
[  ok  ] file provider domains      none
```

Green apart from the two expected warnings, and `SMAppService` reports the login item
**enabled**, not `requiresApproval`. So on a fresh user the "background item added"
notification of section 10 arrives with the item already on, exactly as section 10 claims.

### Adding a domain: enabled, not user-disabled

```
$ sshdrive debug fake add nas --files 8
{ "files": 8, "id": "1B5C5E86-FCA9-4663-9E74-4148BF86FA41", "name": "nas", ... }
$ ls -la@ ~/Library/CloudStorage/
drwxr-xr-x+  3 sshtest  staff    96 Sep  4 02:28 .
	com.apple.FinderInfo	  32
drwx------@  7 sshtest  staff   224 Sep  4 02:28 SSHDrive-nas
	com.apple.file-provider-domain-id	  69
```

`fileproviderctl dump` over the whole output contains **no `user-disabled` and no `⏹`**,
anywhere, for any domain. Our domain's header is bare and its indexer is live:

```
domain: 1{34}1 (n{1}s)
  + features: repl,
  + root: <FPFS>/S{10}s
  + persona: FEEDEEEE-DDDD-CCCC-BBBB-0000000001F6
  + indexer:
      spDomainID:     75957DB8-BDDF-4145-88E7-F25317948B3F
      enabled:        yes
      needs-auth:     no
      errors:         0
      batch-indexed (since last startup): 10
      total-indexable-count: 6

== Domains cache: <GroupContainers>/group.com.apple.FileProvider.DomainCaching/....plist ==
  + com.apple.CloudDocs.iCloudDriveFileProvider
  + org.shirls.sshdrive.fileprovider/1B5C5E86-FCA9-4663-9E74-4148BF86FA41
```

fileproviderd launched the appex without being asked twice:

```
$ ps -o pid,uid,args -U 502
84448  502  Contents/MacOS/SSH Drive
84477  502  /Applications/SSH Drive.app/Contents/PlugIns/SSHDriveFileProvider.appex/Contents/MacOS/SSHDriveFileProvider -LaunchArguments ...
```

and the mount lists and reads:

```
$ ls -la ~/Library/CloudStorage/SSHDrive-nas        # rc=0, immediate
total 8
drwx------@     7 sshtest  staff      224 Sep  4 02:28 .
drwxr-xr-x+     3 sshtest  staff       96 Sep  4 02:28 ..
drwx------@ 65535 sshtest  staff  2097120 Sep  4 02:28 .Trash
drwx------      3 sshtest  staff       96 Sep  4 02:28 Documents
drwx------      2 sshtest  staff       64 Sep  4 02:28 Media
-rw-------      1 sshtest  staff       37 Sep  4 02:28 README.txt
-rwx------      1 sshtest  staff       21 Sep  4 02:28 run.sh
$ ls -R ~/Library/CloudStorage/SSHDrive-nas         # whole tree, incl. Documents/Reports/report-00{0..7}.txt
$ cat ~/Library/CloudStorage/SSHDrive-nas/README.txt
SSH Drive fake backend, milestone 1.
$ sshdrive doctor | tail -2
[  ok  ] file provider domains      nas (1B5C5E86-FCA9-4663-9E74-4148BF86FA41)
```

No approval is pending. `log show --last 8m --predicate 'process == "fileproviderd" OR
subsystem == "com.apple.TCC"'` (2104 fileproviderd lines) has **no** `FP -2011`, no "Sync
is not enabled", no `user-disabled` and no TCC decision naming us; the only `com.apple.TCC`
lines are `Platform binary prompting is 'Deny' because: is Platform Binary` from unrelated
Apple processes. fileproviderd adopted persona `...01F6` for uid 502 and got on with it.

### What this means for section 10

Section 10 is right as written and needs no new user-facing step. The cask's `postflight`
running `open -g -a "SSH Drive"` once registers the login item **and** the extension, and
a domain added afterwards is enabled without any visit to System Settings. The notification
that a background item was added (already enabled) and Gatekeeper's one-time
downloaded-from-the-internet dialog remain the only UI, so `caveats` and `sshdrive doctor`
do **not** have to tell the user to go and flip a switch.

What made it work, as far as this pass can tell: a real signing identity plus the embedded
profiles. The `user-disabled` state that section 0.5 of the runbook records, and that cost
the earlier pass a trip to the GUI, came from the ad-hoc-signed build. It is not what a
cask user gets. Two things this pass does **not** prove, and that stay for S1(f3) on a
notarized artefact: that a *quarantined* bundle opened by `postflight` behaves the same
once Gatekeeper's dialog is answered, and that a Developer ID + notarized signature
behaves as this Apple Development + profile one did.

`sshtest`'s state was deliberately left in place - agent running, extension registered,
domain `nas` present and enabled, mount populated - so the owner can look at
System Settings > Login Items & Extensions > File Providers on the console and see what a
never-touched machine actually shows.

### Two incidental notes

- **`.Trash` is still in `ls -la` on this domain**, minutes after `fake add`, unlike the
  entry below where it vanished after two refusals. It is harmless here: `ls -la` returns
  in well under a second with rc=0, and the fileproviderd log for this domain has **no**
  `fetch-children-metadata(.trash)` at all - no `itemNotFound`, no `materializationFailed`,
  no loop. The system created its trash node (`create-item(propagated:<trash ...>)`,
  then one `update-item ... diffs:nchildren`, both `✅`) and never asked the extension
  about it, so nothing ever refused it and nothing ever removed it. So the fix's guarantee
  is "no hang", not "no `.Trash` entry"; whether the node is swept away afterwards is the
  system's business and varies. Worth re-checking in Finder rather than `ls`.
- macOS has no `timeout`, and **zsh has a `log` builtin** that shadows `/usr/bin/log`
  (`zsh:log:1: too many arguments`). Use the absolute path. A two-line perl
  `alarm`+`exec` wrapper was left at `~sshtest/rt` for the same reason `~alec/rt` exists.

---

## 2026-09-04 - the `.Trash` hang on a mount: diagnosed and fixed

Follow-up to the signed pass below, which found that `ls -la` on
`~/Library/CloudStorage/SSHDrive-nas` never returned. Same VM, same signed Debug build
plus the fix; `scripts/mac-build.sh signed`, installed at `/Applications/SSH Drive.app`,
agent restarted, `nas` re-created with `debug fake remove` / `debug fake add`.

### What the system was actually asking for

From `log stream --predicate 'subsystem BEGINSWITH "org.shirls.sshdrive" OR process ==
"fileproviderd"'`, on a freshly added domain, before the fix:

```
✍️  FS snapshot mutation: insert<s:trash p:trash n:".{4}h/" dir dls child:0 ...> why:item changed
✅  done executing <J2 create-item(propagated:<trash ...>) why:itemChangedRemotely|diskImport>
      → <actual:<s:.trash p:.trash n:".{4}h/" dir child:65533 m:rwxhe ... nsattr:<cap:rw------- cp:system nsp:system>>
‼️  done executing <FP1 fetch-children-metadata(.trash) why:materialization|itemChangedRemotely
      error:<... "itemNotFound(.trash, ...  Domain=NSFileProviderErrorDomain Code=-1005 "The file doesn’t exist.")">
‼️  done executing <FS5 materialize(trash) why:materialization|userRequest
      error:<NSError: libfssync.MaterializationError 3 "materializationFailed">>
```

and then that last pair again at 02:17:25.19, 02:17:26.35, 02:17:27.41 … about once a
second, for ever.

So it is **not** a lookup of a `.Trash` name under the root and **not** `item(for:)`. The
system creates the trash container itself, as a system-owned item
(`cp:system nsp:system`), at `add(domain)` time, and then asks the extension for
`enumerator(for: .trashContainer)` — the call fileproviderd logs as
`fetch-children-metadata(.trash)`. That happens because
**`NSFileProviderDomain.supportsSyncingTrash` defaults to YES** and nothing was setting
it; the header says so in as many words ("This property defaults to YES"). Not setting
`allowsTrashing` (section 5.4) governs only whether an *item* may be trashed; it does not
stop the system from giving the domain a trash.

### What the extension answered, and why that is the loop

`enumerator(for:)` threw `NSFileProviderError(.noSuchItem)` (FP -1005) — written as "No
trash (section 5.4)", which reads right and is exactly wrong. From
`NSFileProviderReplicatedExtension.h`:

> If containerItemIdentifier is NSFileProviderTrashContainerItemIdentifier and the
> extension does not support trashing items, then it should fail the call with the
> NSFeatureUnsupportedError error code from the NSCocoaErrorDomain domain.
>
> If the item requested containerItemIdentifier does not exist in the provider, the
> extension should fail with NSFileProviderErrorNoSuchItem. In that case, the system will
> consider the item has been deleted and attempt to delete the item from disk.

That is the whole bug: we told the system its own trash had been deleted, the system tried
to delete it from disk, the deletion failed because the trash is the system's, it
re-materialized it, and asked again. `ls -la` sat in the `stat` of `.Trash` throughout.
Plain `ls` and `ls -R` never touch it, which is why they were fine.

### The fix

1. `Apps/Agent/DomainManager.swift` - `addDomain` sets `domain.supportsSyncingTrash =
   false` before `NSFileProviderManager.add(domain)`. This is the API's own way of saying
   "no trash" and is what section 5.4 implies; the trashing operation is then the system's
   to decide, which the header says is not guaranteed by contract.
2. `Apps/FileProvider/FileProviderExtension.swift` - `enumerator(for: .trashContainer)`
   now throws `SSHDriveTrash.unsupportedError` (`NSCocoaErrorDomain` /
   `NSFeatureUnsupportedError`, 3328) instead of `.noSuchItem`.
3. Same file, `item(for:)` - the trash container is refused with `.noSuchItem` from
   nothing at all, before the index reader and before any XPC round trip, so a domain
   added by an older build (which still has a trash) cannot make a `stat` of `.Trash` wait
   on the agent.
4. Same file, `createItem` - a create of the name `.Trash` directly under the root is
   refused with the same feature-unsupported error, so that a system which "decides how to
   handle the trashing operation" can never decide to put a `.Trash` directory on
   someone's server.
5. `Packages/SSHDriveCore/Sources/XPCProtocols/Trash.swift` (new) - the identifier, the
   name, the two predicates and that error in one place, with the reasoning. Four tests in
   `Tests/XPCProtocolsTests/TrashTests.swift`, including one asserting the written-out
   identifier still equals `NSFileProviderItemIdentifier.trashContainer.rawValue` and one
   asserting the refusal is *not* `noSuchItem`. `swift test` is **32/32**.

`allowsTrashing` was already never set (`ItemDerivation.capabilities`), on the root row and
on every other row; that half of section 5.4 was correct all along and needed no change.

### Which half of the fix did the work

The domain flag alone would not have been enough. With `supportsSyncingTrash = false` the
system *still* created the trash node and *still* called `fetch-children-metadata(.trash)`
— twice, per `fileproviderctl dump`:

```
i:.trash fetch-children-metadata: 🛑 last:'1788452622 (-4s5ms)' next:'1788452627 (931ms62µs)' count:2
    error:'NSError: Cocoa 3328 "The requested operation couldn’t be completed because the feature is not supported."'
```

What retires it is the answer: on `NSFeatureUnsupportedError` the system throttles, gives
up after those two attempts, and then removes `.Trash` from the mount altogether. The flag
is kept because it is the documented contract and because it decides where a trashing
operation goes; the error code is what stops the loop.

### Verification on the VM

```
$ ls -la ~/Library/CloudStorage/SSHDrive-nas          # 0.02s total, rc=0
total 8
drwx------@ 6 alec  staff  192 Sep  4 02:23 .
drwxr-xr-x+ 4 alec  staff  128 Sep  4 01:00 ..
drwx------  3 alec  staff   96 Sep  4 02:23 Documents
drwx------  2 alec  staff   64 Sep  4 02:23 Media
-rw-------  1 alec  staff   37 Sep  4 02:23 README.txt
-rwx------  1 alec  staff   21 Sep  4 02:23 run.sh
$ ls -la ~/Library/CloudStorage/SSHDrive-nas/.Trash
ls: .../.Trash: No such file or directory
$ ls -R ~/Library/CloudStorage/SSHDrive-nas           # whole tree, rc=0
$ cat ~/Library/CloudStorage/SSHDrive-nas/README.txt
SSH Drive fake backend, milestone 1.
$ cat ~/Library/CloudStorage/SSHDrive-nas/Documents/Reports/report-003.txt   # rc=0
```

`ls -la` immediately after `debug fake add` still shows a `.Trash` for a few seconds,
while the system is creating it and getting refused; it is gone by the time the second
attempt has been answered and it never comes back. Fifty seconds of `log stream` with the
mount idle and two `ls -la` runs in it produced **zero** lines matching `trash` — before
the fix the same window held one `fetch-children-metadata` / `materialize` pair per second.
`sshdrive doctor` is green apart from the two expected warnings.

`~/rt` on the VM is a two-line perl `alarm`+`exec` wrapper written during this session:
macOS has neither `timeout` nor `gtimeout`, and every command that touches the mount wants
one.

### Not done here

Section 5.4's "No trash" paragraph still says only that `allowsTrashing` is never set,
which is the half that was already true and is not the half that mattered. It should gain
a sentence about `supportsSyncingTrash` and the `NSFeatureUnsupportedError` contract.

---

## 2026-09-04 - S1 signed pass, on the headless Mac VM

Same VM (macOS 26.4.1 arm64, 25E253, Xcode 26.4, no GUI), but now with an **Apple
Development** identity (`73XULXLK48`) and a **Developer ID Application** identity in the
login keychain, a development profile for `org.shirls.sshdrive` at
`~/Developer/SSH_Drive.provisionprofile` (`keychain-access-groups = RWGDZAYBM8.*`, this VM
in `ProvisionedDevices`) and one for `org.shirls.sshdrive.fileprovider` at
`~/Developer/SSH_Drive_FileProvider_Testing.provisionprofile` (adds
`com.apple.developer.fileprovider.testing-mode`). Build: `scripts/mac-build.sh signed`,
Debug, installed at `/Applications/SSH Drive.app`. The owner enabled SSH Drive under
System Settings > Login Items & Extensions > File Providers before this pass.
`~/.sshdrive-spike-peer-requirement` was **deleted**: everything below ran against the
build's own code requirement.

### Setup findings, before any sub-question

- **`codesign` over ssh needs the login keychain unlocked.** It fails with
  `errSecInternalComponent` and cannot put a password dialog on a screen nobody is at.
  `launchctl asuser` does not help (it needs root). This VM's login keychain has an empty
  password, so `security unlock-keychain -p "" ~/Library/Keychains/login.keychain-db`
  clears it; `scripts/mac-build.sh signed` does that itself (`UNLOCK_KEYCHAIN=1`,
  `KEYCHAIN_PASSWORD`).

- **Do not put `com.apple.application-identifier` in the app's signed entitlements.**
  This is the one that cost the most time. Xcode writes that key for a profile-signed app
  and it is what the profile's own `Entitlements` matches, so it looks obviously right.
  With it, AMFI refuses to let **launchd** start the agent:
  `AMFI: Launch Constraint Violation (enforcing), error info: c[5]p[1]m[1]e[0]` and
  `xpcproxy exited due to OS_REASON_CODESIGNING | Launch Constraint Violation ... launch
  type 0`, after which launchd removes the service "since it exited with consistent
  failure". Direct exec of the same binary works, and `codesign --verify --deep --strict`
  is happy, so nothing but the launchd path shows it. The agent is the app bundle's own
  **main executable** (section 3), and an executable carrying an application identifier
  may only be launched as an app. Removing the key — leaving exactly
  `Apps/Agent/SSHDrive.entitlements`, i.e. the app group and `keychain-access-groups`, with
  the profile still embedded — makes launchd start it immediately, and the restricted
  entitlement still validates. The extension keeps the key, since it is launched by
  fileproviderd rather than launchd, and needs it for the testing-mode profile to match.

- **`xcodebuild` still cannot sign this project.** Unchanged from the ad-hoc pass: it
  demands a profile it can manage. `signed` mode builds with `CODE_SIGNING_ALLOWED=NO` and
  signs the tree afterwards, inside out, with `--options runtime --timestamp=none`.

### S1(b) - the peer code requirement, evaluated against a real chain

- **b1, both requirement strings parse: PASS** (re-confirmed signed). `csreq` round-trips
  both forms including `certificate 1[field.1.2.840.113635.100.6.2.1] exists`.

- **b2, a peer that fails the requirement is refused: PASS.** See b4.

- **b3, each real build satisfies its own requirement, both directions: PASS.**
  `codesign -v -R <Apple Development form>` returns 0 for all four —
  `SSH Drive.app`, `Contents/MacOS/sshdrive`, `Contents/MacOS/sshdrive-askpass`,
  `Contents/PlugIns/SSHDriveFileProvider.appex` — and the **Developer ID form returns 3**
  (`code failed to satisfy specified code requirement(s)`) for the same files. So the
  marker OIDs, the `certificate leaf[subject.OU] = "RWGDZAYBM8"` clause and the explicit
  identifier list are all right, and a release agent would not admit a debug client.
  With the override file deleted, `sshdrive doctor` is green, which is the same thing
  proved end to end: the agent's listener admits its own CLI.

- **b4, a stranger is refused: PASS.** A copy of `sshdrive` re-signed with the same Apple
  Development identity but `--identifier org.example.notus` fails
  `codesign -v -R` (rc 3) and, run against the live agent, gets
  "Cannot reach SSH Drive's background agent" — the listener drops it. The identifier
  clause, not just the chain, is doing work.

### S1(d) - restricted entitlements

- **d2, the agent reaches the data-protection keychain: PASS.** New hook
  `sshdrive debug keychain [--key K] [--value V]` does one `SecItemAdd` /
  `SecItemCopyMatching` / `SecItemDelete` round trip with
  `kSecUseDataProtectionKeychain = true` and
  `kSecAttrAccessGroup = RWGDZAYBM8.org.shirls.sshdrive`, from the launchd-started agent.
  Result: `addStatus 0`, `readStatus 0`, `matched true`, value read back unchanged. So the
  embedded profile plus `keychain-access-groups` works, and section 3.1's claim that the
  agent is the process with keychain access is confirmed. (The `KeychainSecretsStore`
  itself is still the milestone 2 stub; this hook talks to `SecItem` directly.)

- **d3/d4 (the entitlements half), CLI and askpass carry nothing: PASS.**
  `codesign -d --entitlements -` returns no entitlements blob for either, their
  identifiers are `org.shirls.sshdrive.cli` and `org.shirls.sshdrive.askpass`, both launch
  normally, and both are hardened-runtime signed. **Notarization itself is still not
  done** (that is a Developer ID + `notarytool` exercise for milestone 10), so the
  original d4 stays open.

### S1(a), (e), (f) re-confirmed signed

- **a1, a mach lookup starts the agent: PASS.** `sshdrive agent stop` leaves it down
  (`LastExitStatus 0`, `OnDemand true`); `sshdrive agent start` returns the version JSON
  and `launchctl print` shows `RWGDZAYBM8.org.shirls.sshdrive.agent` with `active = 1`.

- **a2, the sandboxed appex connects: PASS**, and this is the first time it has run.
  `secinitd` logs the container for `<<RWGDZAYBM8/org.shirls.sshdrive.fileprovider;
  signer:development>>`, `SSHDriveFileProvider` appears in `ps`, and listing the mount is
  served through the agent. No sandbox denial on the group-prefixed mach service.

- **b1/b2, e1, e2, f1: PASS**, unchanged. `open -g` returns 0 and registers both halves;
  `pluginkit -m -v -p com.apple.fileprovider-nonui` lists the appex under
  `/Applications/SSH Drive.app`; TERM exits the agent 0 and the next lookup starts it.

- **e3, `add(domain)`: PASS.** The call now returns in ~50 ms rather than blocking (see
  the fixes below). Mount directory: `~/Library/CloudStorage/SSHDrive-nas` for
  `displayName = "nas"`, carrying `com.apple.file-provider-domain-id`.

- **e4, the domain is usable: PASS.** With the extension enabled in System Settings, a
  freshly added domain comes up **without** `user-disabled`, fileproviderd launches the
  appex, and the mount serves. What is still unknown is whether the System Settings switch
  was needed *because* the earlier build was ad-hoc, or whether every fresh install needs
  it: this pass started from an already-enabled provider. Section 10's "the notification
  and the Gatekeeper dialog are the only UI" is therefore still unproven, and a fresh-user
  install is the test.

### S1(c) - a `FileHandle` across NSXPC

- **c1, `fetchContents` writes into the extension's handle: PASS.**
  `cat ~/Library/CloudStorage/SSHDrive-nas/Documents/Reports/report-000.txt` and
  `cat .../README.txt` both return the fake backend's bytes. No `NSXPCConnection` error
  about an unexpected class, so the interface's `Error?` reply parameters, the class
  whitelists and the `FileHandle` argument are all right at runtime (skeleton-notes item
  9). After the fetch the file is no longer dataless. **The runbook's filename is wrong**:
  the seeded files are `report-000.txt` … `report-007.txt`, not `report-1.txt`.

- **c2, a cancelled transfer: still GUI.**

### The headless-VM-feasible parts of S3

- **s3-1 (partial), list / open / remote change: PASS.** `ls -R` returns the whole seeded
  tree (`Documents/Reports/report-00*.txt`, `Media`, `README.txt`, `run.sh`), `cat`
  materializes, and `sshdrive debug mutate nas write Documents/Reports/report-000.txt
  --contents second-version` reaches the replica: the file reads `second-version`
  afterwards. **It is not quick.** Nothing had changed 6 s or 40 s after the mutation; it
  had landed by ~45 s after a second `debug signal`. On an idle headless machine
  fileproviderd throttles the working-set fetch (its schedulers show as ⏳), so any timing
  claim about change latency has to be made on a Mac someone is using. `create-file`
  followed by `delete` within that window never showed up at all, which is consistent with
  the same throttling rather than with a lost anchor: the index and the `anchors` table
  recorded every mutation (`changesSeenBySweep: 1` each time).

- **s3-2 (the mount-path half), naming: recorded.** `displayName = "nas"` gives
  `~/Library/CloudStorage/SSHDrive-nas`. What the Finder sidebar reads is still GUI.

- **s3-5 (first half), mode to `fileSystemFlags`: PASS.** A seeded file with mode 755
  shows as `-rwx------` in the mount and a 644 one as `-rw-------`, so `userExecutable`
  survives to the replica. (The group and other bits are the system's, not ours.)

- **s3-10, the read-only WAL reader inside the sandbox: PASS, as far as a terminal can
  see.** No sandbox denial, no `index reader failed` log line, and the current domain's
  `index.sqlite-shm` picks up an extended attribute the older domains' do not, i.e. the
  sandboxed reader opened it. The measurement in s3-14 still needs the `useReader` CLI
  hook, which does not exist (it is a property of the extension process, so the hook has
  to go through XPC).

- **`.Trash` is a trap, and it is new.** `ls -la` (or anything that stats `.Trash`) on the
  mount **never returns**: fileproviderd loops on
  `fetch-children-metadata(.trash) ... itemNotFound(.trash)` → `materialize(trash)` →
  `materializationFailed`, about twice a second, for good. We set no `allowsTrashing` and
  have no trash (section 5.4), and the system nonetheless keeps trying to materialize one.
  Plain `ls` and `ls -R` are fine. Worth a decision before milestone 4: either serve a
  `.Trash` item or find the flag that stops the system asking. (Both, as it turned out:
  `supportsSyncingTrash` is the flag, `NSFeatureUnsupportedError` is the answer. See the
  entry at the top of this file.)

### Two bugs found while running this pass

- **The extension disconnected its own domain on the way out, permanently.**
  `AgentConnection` called `NSFileProviderManager.disconnect(reason:)` from the
  NSXPCConnection **invalidation** handler. The system kills an idle extension instance,
  the connection invalidates as part of that teardown, and the domain was left
  disconnected; `liftDisconnect()` was guarded on *this instance* having set the flag, so
  the next instance — which starts with the flag clear — never called `reconnect()`. The
  visible symptom was that the root listing worked once and then every request failed with
  `FP -1004 ... NSFileProviderErrorDomainDisconnectionStateKey=4`, i.e. the system, not
  us, refusing. Fixed: invalidation only drops the connection, and the reply to
  `indexReady` calls `reconnect()` unconditionally on every instance launch.

- **A fake-backed location does not survive an agent restart.** `FakeTransport` is an
  in-memory tree, so after the agent exits the location's backend comes back empty while
  the index and the system's replica still hold the old rows; the mount then answers
  `Stale NFS file handle` for everything below the root. Not a product bug — the fake
  backend is a test double — but the runbook needs it: **after any agent restart, run
  `sshdrive debug fake remove <name>` then `debug fake add <name>` before continuing.**

### Fixes made on the Linux side during this session

1. `Apps/Agent/ConfigAccess.swift` (new) - `config.json`'s blocking file I/O now runs on a
   serial queue of its own instead of on the `DomainManager` actor's executor. That is the
   62 s wedge from the ad-hoc pass: `Data.write(to:options:.atomic)` in the group container
   blocked, and because it blocked *inside* the actor every other call queued behind it.
2. `Apps/Agent/Deadline.swift` (new) plus `nonisolated` on `addDomain`, `removeDomain`,
   `signalWorkingSet` and `existingDomainDescriptions` - no File Provider call runs on the
   actor any more, and each is bounded at 20 s, under the CLI's 30 s, so a stalled call
   returns a sentence naming the operation rather than a timeout.
3. `Apps/CLI/AgentClient.swift` - "cannot reach the agent" and "the agent did not answer in
   time" are now different errors. Only a failure to reach the mach service is
   `AgentUnavailable` (and only that triggers the `open -g` relaunch); a reply that never
   arrives is `CommandTimedOut`, and `sshdrive doctor` says which one it was.
4. `Packages/SSHDriveCore/Sources/XPCProtocols/XPCError.swift` (new) - every error the
   agent hands back is flattened first, with the `LocalizedError` description written into
   `userInfo`. NSXPC rebuilds an `NSError` from domain, code and `userInfo` only, so a
   Swift error's description did not survive the trip and the CLI printed
   `Config.ConfigStoreError error 1` instead of `No location matches "nas".` Four tests
   cover it; `swift test` is 28/28.
5. `Apps/FileProvider/AgentConnection.swift` - the sticky-disconnect fix above.
6. `Apps/Agent/ControlCommands.swift`, `Apps/CLI/DebugCommands.swift` - new
   `sshdrive debug keychain` hook for S1(d2).
7. `scripts/mac-build.sh` - new `signed` mode (`app` still means ad-hoc). It embeds
   `~/Developer/SSH_Drive.provisionprofile` at `Contents/embedded.provisionprofile`, keeps
   `keychain-access-groups` on the agent, signs the appex with the sandbox and app-group
   entitlements plus testing-mode and its own embedded profile when
   `~/Developer/SSH_Drive_FileProvider*.provisionprofile` exists (and silently without them
   when it does not), signs the CLI and askpass with their explicit identifiers and no
   entitlements, works inside out with `--options runtime --timestamp=none`, unlocks the
   login keychain first, and finishes with `codesign --verify --deep --strict` and
   `codesign -d --entitlements -` on all five.

### Where index.sqlite and config.json live: not moved, deliberately

The ad-hoc pass suggested moving them out of the extension's
`NSExtensionFileProviderDocumentGroup` path. **There is nowhere to move them to.** The
document group *is* the app group identifier, so its path is the group container itself,
and fileproviderd's own replica lives in a subdirectory of it — `fileproviderctl dump`
reports the extension storage URL as
`<GroupContainers>/RWGDZAYBM8.org.shirls.sshdrive/File Provider Storage`. Everything we
write is already a sibling of that directory, and any other subdirectory would still sit
inside the same coordinated container. Sections 3 and 5.2 also name these exact paths, and
5.2's argument for the read-only WAL reader depends on the index being in the group
container, which the sandboxed extension may write `-shm` into. So the paths stay, the
stall is fixed where it belongs (items 1 and 2 above), and the reasoning is recorded in
`GroupContainer.swift`.

### State the VM was left in

`/Applications/SSH Drive.app` is the **signed** Debug build (Apple Development,
hardened runtime, both profiles embedded), the login item is registered and enabled, the
agent runs from launchd, `sshdrive doctor` is green apart from the two expected warnings
(`CLI on PATH`, `login shell snapshot`), and one working fake location `nas` is mounted at
`~/Library/CloudStorage/SSHDrive-nas` with its tree readable. There is no peer-requirement
override file. The login keychain is unlocked. Three stale `domains/<uuid>/` directories
from earlier runs are left in the group container; they hold nothing and no domain refers
to them.

### What to do next on the VM, in order

1. ~~Decide what to do about `.Trash` before milestone 4~~ - done the same day; see the
   entry at the top of this file.
2. Time the change-detection path on a Mac someone is using; the headless throttling makes
   any latency number from this VM meaningless.
3. Add the CLI hook for `Apps/FileProvider/IndexReaderStore.useReader` (it has to go over
   XPC to the extension) so S3's s3-14 measurement can run.
4. A Developer ID + `notarytool` pass for the real d4, and a fresh-user install to settle
   whether the File Providers switch is needed on a clean machine (e4's remaining half).

---

## 2026-09-04 - S1 on the headless Mac VM (ad-hoc pass)

macOS 26.4.1 arm64 (25E253), Xcode 26.4, no signing identities, no GUI session anyone can
see (there *is* an Aqua session: the console user is auto-logged in, so `open -g`,
`SMAppService` and `launchctl print gui/501` all work over ssh; only clicking does not).
Build: `scripts/mac-build.sh app`, Debug, **ad-hoc signed**, installed at
`/Applications/SSH Drive.app`. The peer code requirement was relaxed for the session with
`~/.sshdrive-spike-peer-requirement` (see the fixes at the bottom).

### Setup findings, before any sub-question

- **`xcodebuild` cannot sign this project at all without a provisioning profile.**
  `CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-` fails with
  `error: "SSHDriveFileProvider" requires a provisioning profile` and the same for
  `"SSH Drive"`, because the app group and `keychain-access-groups` are restricted
  entitlements. The previous `CODE_SIGNING_ALLOWED=NO` build was worse than it looked: it
  produced only a *linker-signed* signature with `Identifier=SSH Drive`,
  `Info.plist=not bound`, `Sealed Resources=none` and **no entitlements at all**, which
  cannot host a File Provider extension. Fixed by ad-hoc signing after the build; see the
  fixes below.

- **Only one copy of the bundle may be registered with LaunchServices.** With
  `~/sshdrive/build/Build/Products/{Debug,Release}/SSH Drive.app` also registered, launchd
  resolved the login item to the wrong bundle and every spawn failed
  (`copy_bundle_path(<uuid>, 501, 0), error 0x6f - Invalid or missing
  Program/ProgramArguments`). `lsregister -u` on both build-directory copies fixed it
  immediately. Worth a line in the developer docs: the debug loop breaks the login item.

### S1(a) - the appex reaches the mach service, launchd starts the agent on the lookup

- **a1, launchd starts the agent on a mach lookup: PASS** (VM).
  `sshdrive agent stop` → no `Contents/MacOS/SSH Drive` process. `sshdrive agent start`,
  which is only a lookup, returned `{"agentVersion":"0.1.0-milestone1","interfaceVersion":1}`
  and the log shows a new pid: `agent starting from launchd` /
  `listening on RWGDZAYBM8.org.shirls.sshdrive.agent`.
  `launchctl print gui/501/org.shirls.sshdrive.agent` shows
  `endpoints = { "RWGDZAYBM8.org.shirls.sshdrive.agent" = { active = 1, managed = 1 } }`,
  `program identifier = Contents/MacOS/SSH Drive (mode: 2)`,
  `parent bundle identifier = org.shirls.sshdrive`, `properties = ... runatload ... has LWCR`.

- **a2, the sandboxed appex connects: BLOCKED (GUI).** The extension process never runs;
  see S1(e4).

### S1(b) - the peer code requirement

- **b1, both requirement strings parse: PASS** (VM). `csreq -r <file> -b <bin>` then
  `csreq -r <bin> -t` round-trips both the Apple Development and the Developer ID form,
  including the `certificate 1[field.1.2.840.113635.100.6.2.1] exists` marker syntax that
  had never been evaluated (skeleton-notes item 2). Syntax only: no certificate chain on
  this Mac evaluates them.

- **b2, a peer that fails the requirement is refused: PASS** (VM).
  `codesign -v -R <appleDevelopment form> "/Applications/SSH Drive.app"` → rc 3,
  `code failed to satisfy specified code requirement(s)`. With no override file the agent
  accepted the connection and then dropped it, and the CLI got
  `NSCocoaErrorDomain Code=4097 "connection to service named
  RWGDZAYBM8.org.shirls.sshdrive.agent"`. That is the correct behaviour for an ad-hoc
  build, and it is why the spike override exists.

- **b3/b4, each real build satisfies its own requirement and a stranger does not: BLOCKED
  (SIGN).** Needs an Apple Development or Developer ID certificate.

### S1(c) - a `FileHandle` across NSXPC

- **c1/c2: BLOCKED (GUI).** No `fetchContents` can be driven while the extension cannot
  start; see S1(e4).

### S1(d) - restricted entitlements

- **d1, what ad-hoc signing costs: PASS, and it is a hard stop.** An ad-hoc signature
  carrying `keychain-access-groups` is killed at exec:
  `open -g` returns `RBSRequestErrorDomain Code=5 "Launch failed" ... NSPOSIXErrorDomain
  Code=163 "Launchd job spawn failed"`, direct exec is `Killed: 9`, and amfid logs
  `Error Domain=AppleMobileFileIntegrityError Code=-424 "The file is adhoc signed but
  contains restricted entitlements"` with
  `Code=-427 "Unable to retrieve certificate chain"`. Removing that one key makes the same
  binary launch. `com.apple.security.application-groups` is **not** rejected ad-hoc: the
  agent runs with it and reaches the container (see below).
  `scripts/mac-build.sh` now strips `keychain-access-groups` when it ad-hoc signs.

- **App group container under an ad-hoc signature: PASS.** `sshdrive doctor` reports
  `[ ok ] app group container /Users/alec/Library/Group Containers/RWGDZAYBM8.org.shirls.sshdrive`,
  and the agent creates `config.json` and `domains/<id>/index.sqlite{,-wal,-shm}` there. No
  dialog, no denial. So the group container needs no team identity, only the entitlement.

- **d2, the data-protection keychain from a profile-carrying bundle: BLOCKED (SIGN).**
  Unblocking it needs, on the VM: an **Apple Development** certificate and private key in
  the login keychain, and a development provisioning profile for `org.shirls.sshdrive`
  that carries `keychain-access-groups` = `RWGDZAYBM8.org.shirls.sshdrive` and
  `com.apple.security.application-groups`, embedded at
  `SSH Drive.app/Contents/embedded.provisionprofile`. That one addition also unblocks b3,
  b4, and very likely a2, c1 and e4.

- **d3, the CLI and askpass carry no restricted entitlements: PASS** (VM).
  `codesign -dvv` gives `Identifier=org.shirls.sshdrive.cli` and
  `Identifier=org.shirls.sshdrive.askpass` (from the embedded `__TEXT,__info_plist`, not
  the product name), and `codesign -d --entitlements -` returns no entitlements blob for
  either. Both launch normally.

- **d4, notarization: BLOCKED (SIGN).**

### S1(e) - `add(domain)` and `open -g`

- **e1, `open -g` registers the login item: PASS** (VM). `open -g -a "/Applications/SSH
  Drive.app"` returns 0 even though the main executable is not an `NSApplication`
  (`LSUIElement`, no `NSApplication`): LaunchServices does not object, so neither
  `LSBackgroundOnly` nor a minimal `NSApplication` is needed (skeleton-notes item 5). The
  app logs `login item registered (status 1)` = `.enabled`, i.e. **no user approval step
  for the login item**, and launchd immediately runs the agent from `RunAtLoad`.
  One cosmetic log line from launchd on every registration:
  `[org.shirls.sshdrive.agent:] Unknown key for plist importer (key: SHA256 type: data)` -
  emitted by `SMAppService`, not by our plist; harmless.

- **e2, `open -g` registers the extension with PlugInKit: PASS** (VM).
  `pluginkit -m -v -p com.apple.fileprovider-nonui` lists
  `org.shirls.sshdrive.fileprovider(0.1.0) ... /Applications/SSH Drive.app/Contents/PlugIns/SSHDriveFileProvider.appex`.
  (An earlier registration of the *unsigned* build-directory copy was rejected by pkd with
  `Ignoring mis-configured plugin ...: plug-ins must be sandboxed`, which is the
  linker-signed-no-entitlements build, not a design problem.)

- **e3, `NSFileProviderManager.add(domain)` from the launchd-started agent: PASS** (VM).
  `sshdrive debug fake add nas` produced
  `added domain 8DA72311-E240-4E3C-8D5D-58800A0B6985 as nas` and
  `~/Library/CloudStorage/SSHDrive-nas` appeared, carrying a
  `com.apple.file-provider-domain-id` xattr (69 bytes) with `com.apple.FinderInfo` on the
  `CloudStorage` directory itself. `fileproviderctl dump` lists the domain under
  `org.shirls.sshdrive.fileprovider`, `containing bundle identifier: org.shirls.sshdrive`,
  `document group name: RWGDZAYBM8.org.shirls.sshdrive`.
  **Early S3 naming data point:** `displayName = "nas"` gives the mount directory
  `SSHDrive-nas`, i.e. the system prefixes the provider's own name with no separator
  spaces. So `SSH Drive - nas` as a display name would give `SSHDrive-SSH Drive - nas`.
  S3 still has to record what the sidebar reads.

- **e4, the domain is usable: FAIL on this VM, BLOCKED (GUI).** The domain comes up
  **user-disabled**. `fileproviderctl dump <domain-id>` prints
  `no process observed; grace period timer not running` and `+ (⏹ user-disabled)`, and
  every scheduled job is throttled with
  `error:'NSError: FP -2011 "Sync is not enabled for “(null)”." ' domain:domainDisabled`.
  The appex is never launched (`extension request grace timer ran out`), and
  `ls ~/Library/CloudStorage/SSHDrive-nas/` ends in `fts_read: Operation timed out`.
  Not fixable from a terminal: `pluginkit -e use -i org.shirls.sshdrive.fileprovider` sets
  PlugInKit's own flag to `+` and does not clear `user-disabled`, `killall fileproviderd`
  changes nothing, and `fileproviderctl` has no enable command. The switch lives in the
  background-task database and is System Settings → General → Login Items & Extensions →
  File Providers → SSH Drive.
  **Open question for the owner:** whether a Developer ID, notarized build comes up
  enabled. If it does not, section 10's claim that the "background item added"
  notification and the Gatekeeper dialog are the only UI a user ever sees is wrong, and
  the cask's `caveats`, the docs and `sshdrive doctor` need a "switch SSH Drive on under
  Login Items & Extensions" step.

### S1(f) - the agent after the bundle is replaced

- **f1, TERM then a lookup: PASS** (VM). `sshdrive agent stop` exits the agent with status
  0, launchd leaves it down (`KeepAlive` `SuccessfulExit=false`, `launchctl list` shows
  `"LastExitStatus" = 0`, `"OnDemand" = true`), and the next lookup starts it again.

- **f2, the bundle deleted and put back: FAIL, and it needs a design answer.** After
  `rm -rf "/Applications/SSH Drive.app"` plus a fresh copy, launchd could no longer resolve
  the login item's bundle: every spawn attempt logged
  `Could not find and/or execute program specified by service: 3: No such process:
  Contents/MacOS/SSH Drive` and
  `Service could not initialize: copy_bundle_path(<uuid>, 501, 0), error 0x6f`, retrying
  on a 10 s throttle forever. The app's unconditional `SMAppService.register()` on every
  launch does **not** repair this: it keeps returning success and logging
  `login item registered (status 1)` while the job stays dead. Only `unregister()` followed
  by a launch clears it. That is exactly the `brew upgrade` / `brew reinstall` shape
  (Homebrew deletes the app, then installs the new one), so section 10's "the app calls
  `register()` unconditionally on every launch, since it is idempotent" is not sufficient
  on its own. Two candidate fixes for the owner to choose between: the app checks whether
  the job can actually run and does `unregister()` + `register()` when it cannot, or the
  cask's `postflight` always unregisters first.
  A `SSHDRIVE_AGENT_ROLE=unregister` role was added to the agent so this is testable and
  scriptable at all; see the fixes below.

- **f3, real `brew reinstall --cask`: BLOCKED (SIGN).**

### S1(g) - Homebrew's `signal:` stanza

- **g1: PASS, and it settles section 10 against section 3.1.**
  `launchctl list | grep -i sshdrive` prints exactly one line:
  `75700	0	org.shirls.sshdrive.agent`. The bundle identifier `org.shirls.sshdrive` does
  **not** appear anywhere in `launchctl list`. Homebrew matches the string in `signal:`
  against that output, so section 10's `signal: ["TERM", "org.shirls.sshdrive"]` would
  find nothing and the cask must carry `signal: ["TERM", "org.shirls.sshdrive.agent"]`.
  This resolves skeleton-notes item 4; section 10 needs the edit and section 13 a dated
  pointer.

### Two things worth recording that no sub-question asked for

- **A stalled `NSFileProviderManager` call wedges the whole agent, and the CLI blames the
  wrong thing.** With the disabled domain present, `Data.write(to:options:.atomic)` on
  `config.json` inside the group container blocked for about three minutes; `sample`
  caught it at
  `DomainManager.start() → ConfigStore.load() → ConfigStore.save() → Data.write(to:options:)
  → createProtectedTemporaryFile → open`, while fileproviderd logged a continuous stream of
  `NSFileCoordinator requested ... to provide item` for `org.shirls.sshdrive.fileprovider`.
  Because those writes happen inside the `DomainManager` actor, every other actor call
  queued behind them, so `debug fake list`, `debug fake add` and `debug fake remove` each
  returned after exactly 62 s (two 30 s `AgentClient` timeouts) with
  *"Cannot reach SSH Drive's background agent"* while the agent was in fact alive and
  answering `ping` and `doctor`. Both halves are worth fixing before milestone 3: the
  index and `config.json` live in the same app-group container that is the extension's
  `NSExtensionFileProviderDocumentGroup` (fileproviderd's dump shows
  `extension storage URLs: <GroupContainers>/RWGDZAYBM8.org.shirls.sshdrive/File Provider Storage`),
  and the CLI should distinguish "no answer on the mach service" from "the agent took too
  long". Whether the stall survives a *working* extension is unknown and should be
  re-checked as soon as e4 unblocks.

- **`NSFileProviderManager.remove(domain)` on a disabled domain does not return** within
  three minutes either, so the leftover domain could not be cleaned up. See the VM state
  note at the end.

### Fixes made on the Linux side during this session

1. `scripts/mac-build.sh` - new ad-hoc signing step after `xcodebuild` (and a `sign`
   mode). It signs innermost-first with the four real identifiers and the real entitlement
   files, and strips `keychain-access-groups`, which AMFI refuses on an ad-hoc signature.
   Without this the "built and signed" bundle had no entitlements and the wrong signing
   identifier.
2. `Packages/SSHDriveCore/Sources/XPCProtocols/CodeRequirement.swift` - debug-only spike
   override, from `SSHDRIVE_PEER_REQUIREMENT` or `~/.sshdrive-spike-peer-requirement`. The
   file, not just the environment, because launchd hands an `SMAppService` job a scrubbed
   environment: `launchctl setenv` is visible to `launchctl getenv` and never reaches the
   job (`inherited environment` carries only `SSH_AUTH_SOCK`). Release builds ignore both.
3. `Apps/Agent/ListenerDelegate.swift` - logs at error level whenever the override is in
   force.
4. `Apps/Agent/main.swift` - `SSHDRIVE_AGENT_ROLE=unregister` calls
   `SMAppService.unregister()` and exits, which is the only way found to clear a login-item
   registration whose bundle was replaced (S1(f2)).

### State the VM was left in

`/Applications/SSH Drive.app` is the ad-hoc Debug build, the login item is registered and
enabled, the agent runs, and `sshdrive doctor` is green apart from the two expected
warnings (`CLI on PATH`, `login shell snapshot`). One leftover **disabled** domain remains,
`nas` = `8DA72311-E240-4E3C-8D5D-58800A0B6985`, with
`~/Library/CloudStorage/SSHDrive-nas` that times out on access; it cannot be removed until
the extension is enabled. `~/.sshdrive-spike-peer-requirement` is in place; delete it to
put the build's own requirement back.

### What to do next on the VM, in order

1. Enable **SSH Drive** under System Settings → General → Login Items & Extensions → File
   Providers (someone at the machine, or Screen Sharing). Then
   `sshdrive debug fake remove nas` to clear the leftover, and re-run S1(a2), S1(c1) and
   S1(e4).
2. Install an Apple Development certificate and a matching development provisioning
   profile for `org.shirls.sshdrive` (app group + `keychain-access-groups`), so
   `xcodebuild` can sign normally. That unblocks S1(b3), S1(b4) and S1(d2), removes the
   need for the spike requirement override, and is the first thing to try if the extension
   still will not start once the switch is on.
3. With the extension running, S3, S4 and S6 become mostly a GUI exercise; only S3's
   reader-versus-XPC measurement (s3-14) needs a code change first, a CLI hook for
   `Apps/FileProvider/IndexReaderStore.useReader`.
