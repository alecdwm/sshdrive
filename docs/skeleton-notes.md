# Milestone 1, "Skeleton": what is here

Scaffold for DESIGN.md section 12 milestone 1. Everything the design assigns to
milestones 3 to 10 is still a stub with a TODO naming the milestone.

Milestone 2, the transport, landed on top of it on 2026-09-04 and is marked
through this file rather than in one of its own: `Secrets`, `SSHProcess` and the
real `SFTP` client are no longer stubs, a location with `backend: sftp` mounts
for real, and the `debug secrets` and `debug ssh` hook sets are documented below.
The spike runbook for it is `docs/spikes/milestone-2.md`.

Built and tested on macOS 26.4.1 arm64, Xcode 26.4, Swift 6.3 (Swift 5 language mode),
xcodegen 2.46. `scripts/mac-build.sh` does the sync, generate, `swift test` and
`xcodebuild` loop; the Mac used for it has no signing identities, so it builds ad-hoc
signed. `project.yml` keeps the real Developer ID settings and the script overrides them
on the command line only.

## What compiled and ran

- `swift build` and `swift test` in `Packages/SSHDriveCore`: **33** tests, 0 failures at
  the skeleton (RelativePath validation, the fake transport's non-overwriting rename and
  its invisible-rewrite case, the config store, the index writer and the read-only reader,
  anchors, anchor expiry, subtree path rewriting, `VACUUM INTO` backup). With milestone 2's
  three modules and their merge it is **214** tests, 0 failures: 31 are skipped without the
  spike testbed, and with `SSHDRIVE_TESTBED=1` on the build VM 212 run and 2 skip, those
  two being the ones that need a real Mac (2026-09-04).
- `xcodebuild -scheme "SSH Drive"` in **both Debug and Release**: BUILD SUCCEEDED, no
  warnings from our own sources.
- The produced bundle is exactly the tree in section 3:
  `Contents/MacOS/{SSH Drive,sshdrive,sshdrive-askpass}`,
  `Contents/PlugIns/SSHDriveFileProvider.appex`,
  `Contents/Library/LaunchAgents/org.shirls.sshdrive.agent.plist`.
  (`ENABLE_DEBUG_DYLIB: NO` keeps Xcode's debug-dylib split out of `Contents/MacOS`.)
- `sshdrive --help` runs and lists `doctor`, `agent`, `debug`.
- The CLI carries an embedded `__TEXT,__info_plist` whose `CFBundleIdentifier` is
  `org.shirls.sshdrive.cli` (confirmed with `otool -s __TEXT __info_plist`), which is what
  the agent's peer requirement matches; a bare tool's default identifier would be its
  product name and would be refused (section 3.1).
- Both `NSExtensionFileProviderActions` activation rules parse as `NSPredicate`.
- The literal the index uses for the root row equals
  `NSFileProviderItemIdentifier.rootContainer.rawValue`
  (`"NSFileProviderRootContainerItemIdentifier"`), checked on the Mac.

Nothing was run as a login item or connected over XPC: that is spike S1, and it needs a
signed build.

## Real code

| Where | What |
|---|---|
| `Packages/.../XPCProtocols` | `SSHDriveAgentProtocol`, `SSHDriveExtensionProtocol`, the configured `NSXPCInterface`s with their class whitelists, `SSHDriveItemSnapshot`/`SSHDriveItemPage` (NSSecureCoding), `SSHDriveAgentError`, every identifier from section 3.1, and the peer code requirement. |
| `Packages/.../Config` | The section 4 location model, `config.json` in the app-group container, atomic writes, `<name>` resolution (nickname, host, id prefix). |
| `Packages/.../Index` | The full section 5.3 schema (`items`, `anchors`, `roots`, `held`, `meta`), a small SQLite wrapper, `IndexWriter` (agent, sole writer: upsert, delete with its deletion anchor, subtree path rewrite, anchor append/prune/expire, roots, `VACUUM INTO` backup, `reconciling` and `generation`), `IndexReader` (extension, read-only WAL, meta checks, `item`, `children`, change stream with `.syncAnchorExpired`), and the row-to-snapshot conversion both sides share. |
| `Packages/.../SFTP` | `RelativePath` (the section 9.1 chokepoint, byte components), `SFTPTransport`, the section 6.2 error classes, and `FakeTransport`: an in-memory tree with list, fetch, write, rename (non-overwriting), posix-rename, delete, symlink, statvfs, plus the mutation hook. Since 2026-09-04 (milestone 2) also the real thing: the SFTP v3 wire codec, `SFTPClient` with pipelining, per-request deadlines and the OpenSSH extensions, and `RealSFTPTransport`, which is the only place a `RelativePath` becomes an absolute server path. It sits on `SSHProcess`'s `ByteStream`. |
| `Packages/.../SSHProcess` | Real since 2026-09-04 (milestone 2): `SSHCommandBuilder` (every `ssh` command line of section 6.1), `SSHMaster` (the `-N` ControlMaster, its `SFTPChannel` and `ExecChannel` mux clients, the askpass token it mints per spawn), `ProxyChainBuilder`, `RemoteScript` with the section 9.2 sentinel and the section 6.4 heartbeat wrapper, `LoginShellSnapshot`, `SSHExitClassifier`, `IdentityAgentCheck`, `ControlSocket` and its orphan sweep, and `Spawn` (`posix_spawn` with a real `argv[0]`). |
| `Packages/.../Secrets` | Real since 2026-09-04 (milestone 2): `KeychainSecretsStore` on the data-protection keychain, `AskpassBroker` (the section 4.2 token protocol and the answer table), `AskpassPromptClassifier`, `SSHGResolver`, `ProcessAncestry`, and the `AskpassHarness` seam the tests drive it through. |
| `Packages/.../Logging` | The section 3.1 subsystem and categories. |
| `Apps/Agent` | Two-role `main.swift` (launchd agent vs `open -g` registrar), `SMAppService` registration, the `NSXPCListener` on the group-prefixed mach service with `setCodeSigningRequirement`, `DomainManager` (`NSFileProviderManager.add`/`remove`/`signalEnumerator`), `LocationRuntime` (listing reconcile against the index, fetch through the peer's `FileHandle`, create/modify/delete, catch-up sweep, pin marker), `ItemDerivation` (section 5.4 capabilities and `fileSystemFlags`, stable metadata version), `ControlCommands` (`doctor` plus the debug hooks), and `SpikeHooks` (the File Provider calls S4 and S6 need: `evictItem`, the materialized and pending sets, `getUserVisibleURL` plus `lstat`, the stabilization barrier and the testing-mode scheduler). |
| `Apps/FileProvider` | `NSFileProviderReplicatedExtension` with `item(for:)` answered from the read-only index reader and an XPC fallback, container and working-set enumerators, `fetchContents` over a `FileHandle` with a cancellable `Progress`, `createItem`/`modifyItem`/`deleteItem`, `disconnect(reason:)`/`reconnect()` on an unreachable agent, and the agent-error to `NSFileProviderError` mapping. |
| `Apps/CLI` | `sshdrive` on ArgumentParser: `doctor` (fully implemented for the skeleton's checks), `agent start|stop|restart`, and the `debug` group. Pure XPC client, with the `open -g` relaunch of section 8. |
| `Apps/Askpass` | `sshdrive-askpass`: reads the token, the prompt, `SSH_ASKPASS_PROMPT` and its parent `ssh`'s argv (`sysctl KERN_PROCARGS2`), calls the agent over the askpass-only interface, prints the answer. An empty line is "skip this identity"; a non-zero exit fails the prompt. |

## Stubbed, with the milestone named

- ~~`Secrets` (`KeychainSecretsStore`): keys and shape only~~ - real since 2026-09-04
  (milestone 2): the data-protection keychain, the askpass token protocol, prompt
  classification. The collect flow's relay to the CLI has the seam but no CLI: that is
  `sshdrive add`, milestone 3.
- ~~`SSHProcess`: `/usr/bin/ssh -V` for `doctor` is real; the master, mux clients,
  ProxyJump chain, login-shell snapshot and `ssh -G` are milestone 2~~ - real since
  2026-09-04. `doctor` now prints the login shell snapshot it took.
- ~~`LocationBackend.sftp` raises "milestone 2" from `DomainManager`; only `.fake` runs~~ -
  a `.sftp` location gets an `SSHBackedTransport` (2026-09-04): login shell snapshot,
  `-N` master with a token of its own, an SFTP channel on its mux socket, the wire client
  on that channel, and `realpath` of the root verified on every connection. What it adds
  over `RealSFTPTransport` is the two things the extension is owed before section 6.3
  lands in milestone 5: **every transport call has a wall-clock deadline** (25 s for
  metadata, an hour for a transfer, since the wire client re-arms its own while bytes
  arrive) and **a lost master is reported as `.serverUnreachable`** rather than as
  whatever the dying channel said. The `NWPathMonitor` gate, the circuit breaker and
  reconnection with backoff are still milestone 5, and there is still only one SFTP
  channel: the bulk channel and the transfer scheduler of section 6.2 arrive with
  milestone 3's fetching.
- `fetchPartialContents` (milestone 3), the temp-file plus rename upload, conflict copies,
  symlink containment, `.DS_Store` (milestone 4), reconcile walk and restore-into-live
  (milestone 5), root-set rotation and the mass-deletion guard (milestone 6), eviction
  (7), real pin/unpin and `performAction` (8), helper (9, placeholder `helper/README.md`).
- Directory paging, name-collision hiding and non-UTF-8 hiding: entries are skipped, not
  yet recorded with `hidden = 2`. Milestone 3.
- Every section 8 command other than `doctor`, `agent` and `debug`.

## `sshdrive debug` hooks, exact syntax

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
sshdrive debug signal <name> [--container PATH]
sshdrive debug keychain [--key K] [--value V]

# Added 2026-09-04 for milestone 2 (the transport, spike S2):
sshdrive debug ssh add <name> <[user@]host[:port]> [--remote-path P]
                                                  [--identity FILE] [--jump CHAIN]
sshdrive debug ssh remove <name>

# Added 2026-09-04 for milestone 2 / spike S2 (the askpass token protocol):
sshdrive debug secrets [store|lookup|delete|list|classify|connect]
        [--key ACCOUNT] [--destination user@host] [--port N] [--identity PATH]
        [--value V] [--prompt TEXT] [--kind confirm|none] [--command CMD]
        [--host-key-checking yes|ask|accept-new] [--jump CHAIN]
        [--purpose master|collect] [--with-key-agent]

# Added 2026-09-04 for spikes S4 and S6:
sshdrive debug evict <name> <path>
sshdrive debug materialized <name> [--pending]
sshdrive debug stat <name> <path> [--read]
sshdrive debug xattr <name> <path>
sshdrive debug fault <name> [--writes on|off] [--fetch-delay MS]
                            [--version-mismatch on|off] [--collisions on|off]
sshdrive debug transfers <name> [--reset]
sshdrive debug stabilize <name>
sshdrive debug testing <name> list|run
sshdrive debug fake add <name> [--files N] [--testing-modes always,interactive]
```

Notes for whoever writes the runbook:

- `fake add` creates the location, seeds the tree, enumerates the root once and adds the
  File Provider domain. `<name>` becomes the nickname and the domain's display name, so
  S3 can compare `nas` against `SSH Drive - nas` by creating two.
- Every `mutate` runs the catch-up sweep afterwards and signals the working set, so a
  mutation reaches Finder the way a remote change would. `rewrite-invisibly` keeps size
  and second-mtime and moves only ns-mtime and inode: that is the case the `generation`
  column exists for (section 5.3).
- For S3's anchor-expiry question, run `sweep <name> off` first, then
  `anchor expire <name>`, so the system's own re-enumeration is visible rather than ours.
- `policy <name> <path> eager-keep` sets the pin marker, serves
  `.downloadEagerlyAndKeepDownloaded` and drops `allowsEvicting`, which is what S6 needs.
- `index dump` prints identifiers, paths, both versions, the derived bitmasks and the
  pin/kept state.
- `Apps/FileProvider/IndexReaderStore.useReader` is the switch for S3's reader-vs-XPC
  measurement. It is a stored property with no CLI hook yet; add one, or flip it in the
  debugger, when running that measurement.

### The 2026-09-04 hooks (milestone 2: `debug secrets`)

`Secrets` is no longer a stub. The keychain wrapper (DESIGN.md section 4.2) is real, and
so is the askpass token protocol: `Apps/Agent/AskpassService.swift` exports a one-method
XPC interface (`SSHDriveAskpassProtocol`, in `Sources/XPCProtocols/AskpassProtocol.swift`)
to `sshdrive-askpass` and to nothing else, and everything behind it -
token minting and retiring, prompt classification, the keychain lookups, the misses a
collect connection records - lives in `Sources/Secrets/` and is unit-tested without an
`ssh` anywhere through `AskpassHarness`.

`debug keychain` above stays: it is the S1(d2) `SecItem` round trip and talks to
`SecItem` directly. `debug secrets` drives the real store and the real askpass path, and
only the launchd-started **signed** agent can run either, because
`keychain-access-groups` needs the embedded provisioning profile (section 3.1).

- **`secrets store|lookup|delete`** - one keychain item. Name it either as an account
  (`--key password:user@host:port`, `--key passphrase:/abs/path`) or by parts
  (`--destination user@host --port N`, or `--identity ~/.ssh/id_nas`). A stored value
  never comes back out: `lookup` reports `found` and its length, and `matches` when
  `--value` is given to compare against.
- **`secrets list`** - every item in `RWGDZAYBM8.org.shirls.sshdrive` under the
  `org.shirls.sshdrive` service, with the `list`/`show` sentence section 4.2 specifies
  ("password stored for alec@nas"), plus any account that does not parse as one of our
  two key shapes (the S1 hook's `spike:s1d2` shows up there).
- **`secrets classify --prompt TEXT [--kind confirm|none]`** - what the agent makes of a
  prompt. Useful for checking a prompt shape a new server produces without connecting to
  it.
- **`secrets connect --destination user@host --port N`** - spawns one real `/usr/bin/ssh`
  from the agent's own environment with `SSH_ASKPASS`, `SSH_ASKPASS_REQUIRE=force` and a
  freshly minted `SSHDRIVE_ASKPASS_TOKEN`, and reports the exit status, stdout/stderr, how
  many prompts were raised, how many were answered from the keychain, every miss (prompt
  text and the key it would have used), any refusal, and any key that asked for a touch.
  `--identity PATH` adds `IdentitiesOnly=yes -i PATH`; `--jump user@host:port` builds a
  single-hop `ProxyCommand` the way section 6.1 wants (`ControlMaster=no` **and**
  `ControlPath=none`, `-W '%h:%p'`); `--host-key-checking ask` is how the host-key refusal
  is exercised; `--purpose collect` mints a collect token; `--with-key-agent` drops the
  `IdentityAgent=none` that is otherwise always passed. The command line here is
  deliberately minimal - the real master and its mux clients are section 6.1's job, in
  `SSHProcess`.

  **This hook stores nothing.** It is `sshdrive add`'s ancestor, not `add`: put the item
  in place with `secrets store` first, then `connect` proves the agent can use it with no
  tty. Milestone 3's `add` replaces it. Since 2026-09-04 it runs in the same
  environment a master does (launchd's, plus the login shell snapshot's `PATH` and
  `SSH_AUTH_SOCK`), which is what makes `--with-key-agent` able to reach an agent whose
  socket is exported from `.zshrc`, and `--jump` takes a whole comma-separated chain built
  by `ProxyChainBuilder` rather than the single hand-rolled hop it used to have.

### The 2026-09-04 hooks (milestone 2: `debug ssh`)

`sshdrive debug ssh add <name> <[user@]host[:port]>` writes an **ssh-backed** location and
adds its domain, so the milestone 2 transport can be driven end to end before milestone 3
exists. It is deliberately not `sshdrive add`: there is no `ssh -G` display, no two-pass
collect connection and no prompt relayed to the terminal, which are the three things the
real command adds (section 8, section 4.2). It writes the location from what it is given
and connects with whatever the keychain already holds, so put the secrets in place with
`debug secrets store` first.

- `<[user@]host[:port]>` - `user@host:port` is our own sugar, split here and passed as
  `-o User=` and `-o Port=`, because `ssh` does not parse that form (section 6.1). The host
  may be a `~/.ssh/config` alias, which is how the two-hop chain is reached
  (`debug ssh add inner spike-inner`).
- `--remote-path P` - the directory to mount. Default is the account's home, as SFTP
  `realpath` of `.` resolves it.
- `--identity FILE` - stored as the location's `identityFile`, together with
  `IdentitiesOnly=yes` in `sshOptions`, which is what section 4 says `--identity` means.
- `--jump CHAIN` - one or more `[user@]host[:port]`, comma separated, stored as
  `-o ProxyJump=<chain>` in `sshOptions`. It reaches `ssh -G`, where the chain builder
  reads it; it is stripped from the master's own command line, so section 6.1's "`ProxyJump`
  is never handed to `ssh`" holds for this route too.

The command is all-or-nothing: a location that cannot connect is removed again rather than
left in `config.json` pretending to be mounted, because unlike the real `add` it has no
terminal to explain itself to. `debug ssh remove <name>` takes the domain, the index, the
location and the location's `ssh` master (`-O exit`) away; it is the same handler as
`debug fake remove`.

Two implementation notes worth carrying forward:

- The listener hands a peer whose executable is `sshdrive-askpass` the askpass interface
  and the agent interface to everyone else (`AskpassService.register`, one line in
  `ListenerDelegate`). The peer code requirement is still the boundary; this only decides
  *which* of our four executables gets *which* interface, so the path that hands out
  secrets cannot also remove a location. ~~The older `askpassAnswer` method on
  `SSHDriveAgentProtocol` is now unused and should go~~ - removed 2026-09-04; the askpass
  path is `SSHDriveAskpassProtocol` and nothing else.
- ~~`SSHProcess` grew its own `AskpassEnvironment` in parallel with the one in `Secrets`~~ -
  merged 2026-09-04 into `Sources/XPCProtocols/AskpassEnvironment.swift`, which agent,
  askpass, `Secrets` and `SSHProcess` can all see. Beside it lives `AskpassTokenProviding`,
  the seam the two modules meet on: `SSHMaster` mints a token per spawn, attaches the
  child's pid and retires the token when the master goes, while `AskpassBroker` is what
  actually holds it and answers the prompt. Neither module depends on the other.

### The 2026-09-04 hooks (S4, S6)

The File Provider half of these lives in `Apps/Agent/SpikeHooks.swift`; the fault
injection and the transfer accounting are on `LocationRuntime`. They are in the agent
because the agent is the process that will make the same calls for real: the TTL loop of
section 7 evicts and stats, and the pin machinery of section 7.1 signals. `sshdrive
evict`, `sshdrive pin` and the eviction timer replace them in milestones 7 and 8.

- **`evict <name> <path>`** - `NSFileProviderManager.evictItem` on the row's identifier.
  The reply is the error's `domain`, `code`, `underlyingErrors` and `userInfo` keys rather
  than a sentence, because which error comes back is the whole answer, plus the row's own
  `kept` and whether it was served `allowsEvicting`. On this OS it works on files,
  directories (recursively) and `.rootContainer`.
- **`materialized <name> [--pending]`** - walks `enumeratorForMaterializedItems`, or
  `enumeratorForPendingItems`, and annotates each identifier with the path, `kept` and
  `pin_state` from the index. The materialized set is the enumerator section 7's loop uses,
  and it is the only headless way to see what an eager policy actually downloaded.
- **`stat <name> <path> [--read]`** - `getUserVisibleURL` for the item, then `lstat` with
  the errno kept: atime, mtime, ctime, birthtime, size, `st_blocks`, `st_flags` and a
  `dataless` bit (`SF_DATALESS`, 0x40000000). `--read` opens and reads one byte first.
  This is exactly how section 7's loop will read the replica, and it doubles as the
  TCC probe (s4-5). It also has a side effect worth knowing: **a `getUserVisibleURL` plus
  `lstat` of a path whose ancestors the system has never enumerated is what makes the
  system ingest that chain** (s6-3), which is the missing half of section 7.1 step 1.
- **`xattr <name> <path>`** - the extended attributes the index serves for the row, next to
  the metadata version their hash feeds. Compare with `xattr -l` in the mount: they differ,
  because the system only hands the extension xattrs it considers syncable.
- **`fault <name> [--writes on|off] [--fetch-delay MS]`** - `--writes on` fails every
  `createItem`/`modifyItem` with `.serverUnreachable`, so an edit made in the mount stays
  in the system's pending set (that is the item s4-3 tries to evict). `--fetch-delay` holds
  each `fetchContents` open for that many milliseconds; a fake-backed fetch is a memory copy
  that finishes before the next one starts, so without it the concurrency s6-11 counts is
  always 1. `--version-mismatch on` makes `modifyItem` reply with content and metadata
  versions that are not the ones just written, which is how s3-7 found that the system takes
  the reply at face value and never re-fetches; `--collisions on` makes every `createItem`
  fail `.filenameCollision`, which is how s3-4 found that the system then retries the create
  for ever with no alert. **Turn all four off before leaving the VM.**
- **`transfers <name> [--reset]`** - in-flight, peak concurrent and total `fetchContents`,
  with a per-fetch timeline (start and end, seconds from the first) so the overlap is
  visible rather than inferred from a peak.
- **`stabilize <name>`** - `waitForStabilization` then `waitForChanges(below: .rootContainer)`.
  On an idle headless Mac fileproviderd throttles its schedulers, so without this a spike
  measures the throttle rather than the behaviour. It is **not** a download barrier: it
  returns in under a second and the background-download scheduler still takes 8-90 s.
- **`testing <name> list|run`** - `listAvailableTestingOperations` and `run(_:)`, which the
  appex's `com.apple.developer.fileprovider.testing-mode` entitlement unlocks. They only
  return anything on a domain added with `--testing-modes interactive`; on any other domain
  the error is printed rather than thrown, because the error is the useful part. Nothing in
  S4 or S6 needed it: interactive mode disables the system's own scheduling, which is the
  behaviour those spikes measure, and the header says the mode cannot be removed from a
  domain once given.
- **`signal <name> --container PATH`** - `signalEnumerator(for:)` on one folder rather than
  the working set. Recorded because it does *not* solve s6-3: signalling a never-enumerated
  ancestor's own enumerator changes nothing.
- **`fake add --testing-modes always,interactive`** - `alwaysEnabled` brings the domain up
  without the user approving the provider, `interactive` hands the scheduler to the hook
  above. Never set on a real location.
- **`policy <name> <path> …`** now readdirs every missing ancestor into the index before
  setting the marker and reports which rows it created, which is section 7.1 step 1. It
  also serves a real `.downloadLazily` for `pin_state = -1`; it used to serve "no opinion",
  under which an eager ancestor would simply have won and exclusions could not work.

## Verify on Mac (what the compiler could not settle)

1. **The whole of S1.** Nothing here has been signed, registered or connected. In
   particular: that a sandboxed appex reaches the group-prefixed mach service, that
   launchd starts the agent on that lookup, that a `FileHandle` crosses NSXPC and the
   agent can write through it, and that `NSFileProviderManager.add(domain)` from the
   launchd-started agent associates the domain with our extension.
2. **The code requirement strings** in `CodeRequirement.swift`. The marker OIDs and the
   `certificate 1[...] exists` syntax were never evaluated. Check each build's own chain
   with `codesign -v -R="<string>"` against all four executables before trusting the
   listener. Derivation: release uses the Developer ID leaf and intermediate markers,
   debug the Apple Development leaf and the WWDR intermediate, chosen by `#if DEBUG`, so
   a release agent never admits a debug client.
3. **The launchd plist.** `SMAppService.agent(plistName:)` with `BundleProgram`,
   `MachServices`, `AssociatedBundleIdentifiers` and an `EnvironmentVariables` entry
   (`SSHDRIVE_AGENT_ROLE=launchd`, which is how the same binary tells its two roles
   apart) is written from the documentation, not from a working registration.
4. **Section 10 vs section 3.1: the cask `signal:` label.** Section 10 writes
   `signal: ["TERM", "org.shirls.sshdrive"]` while section 3.1 gives the launchd label as
   `org.shirls.sshdrive.agent`. Not resolved here, as instructed: this repo's plist uses
   `Label = org.shirls.sshdrive.agent`. Homebrew matches the bundle id against
   `launchctl list` output, so S1(g) is what decides which string the cask must carry.
5. **An `.app` whose main executable is not an `NSApplication`.** `open -g -a "SSH Drive"`
   is assumed to launch it, let it register and let it exit 0. If LaunchServices objects,
   the fix is `LSBackgroundOnly` or a minimal `NSApplication`.
6. **Restricted entitlements.** `keychain-access-groups` needs a Developer ID
   provisioning profile embedded in the bundle, and
   `com.apple.developer.fileprovider.testing-mode` needs to be accepted for debug builds.
   Neither is exercised by an ad-hoc build.
7. **The extension's read-only WAL reader from inside the sandbox** (S3), including that
   a read-only connection may open `-shm` for writing in the group container, and the
   reader-vs-XPC measurement that decides whether the reader survives at all.
8. **`NSFileProviderManager.disconnect(reason:options:)` called from inside the
   extension** (S5). If it is not allowed, the message lives only in `sshdrive doctor`.
9. **The NSXPC interface at runtime.** The class whitelists, the `Error?` reply
   parameters and the `FileHandle` arguments compile, but only a live connection proves
   the interface accepts them.
10. ~~**`contentPolicy = .inherited` as the neutral value** for an unpinned item~~ -
    confirmed 2026-09-04 (s6-12): it forces nothing. Whether Finder's context menu shows
    our two actions at the top level is still open (s6-8) and needs a screen. The rules
    themselves were dead until 2026-09-04 evening: the bound key is `fileproviderItems`
    (lower-case p) and it is a key path, not a `$` substitution variable - either mistake
    drops the entry silently. Fixed in `Apps/FileProvider/Info.plist`; the corrected rules
    evaluate under `fileproviderctl evaluate`.
11. **Finder's own "Keep Downloaded".** Finder 26.4 ships strings for a built-in
    `Keep Downloaded` entry and a `Kept Downloaded` badge, and our custom action uses the
    same label (section 7.2). Whether Finder offers its own to a third-party provider needs
    a screen; our items report `isKeepDownloaded = 0` even under an eager policy, so the
    flag is the system's own (s6-7).
12. **Dropping `allowsEvicting` changes nothing** on 26.4: the system reports the bit set on
    a pinned, downloaded item whose row cleared it, and clears it on any dataless item. The
    documented per-provider lever is
    `NSExtensionFileProviderAllowsUserControlledEviction = false` (s6-7).
