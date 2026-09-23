# Testing

The whole suite runs on Linux, against models of macOS and of servers that encode every behaviour
measured so far. The Mac VM only measures: it seeds the models, and a green Linux suite is what
proves a change.

## The principle

In the owner's words:

> "I would like as much of the testing as possible to be done in a way that encodes mocks
> measured/known macOS behaviour and then exercises the codebase against all known issues
> identified in the past. If future macOS releases cause breakage, we can then add their
> behaviour into the encoded mocks and thereby unit test across all supported macOS versions
> (and each one's quirks) without needing to spin up VMs and such. The tests should be able to
> run 100% isolated on a Linux box. We should only use the VM to seed the macOS mocks into the
> tests."

## Running the suite

On Linux, where the suite is the gate:

```sh
. ~/.local/share/swiftly/env.sh
cd Packages/SSHDriveCore
swift test
cd ../../helper && cargo test && cargo clippy -- -D warnings
```

No Mac, no VM, no network, no testbed, no `docker compose`. The run is 819 XCTest tests with 41
skipped, 65 swift-testing tests in twelve suites, and 54 crate tests for the helper. The 41 skips
are the testbed-backed tests in `SFTPTests` and `SSHProcessTests`, gated on `SSHDRIVE_TESTBED=1`.
The testbed answers the build VM and nothing else, so they are inert here.

### On the build VM

The same `swift test` must be green on the VM too. It is the same scenarios against a different
box, not a second suite:

- Extra tests: the mirrored-constant assertions, which need Apple's frameworks (see
  [the extension's seams](#the-extensions-providercore)).
- Extra skips: rows whose premise a Mac cannot hold, each skipping by name
  (see [the box is a seam too](#the-box-is-a-seam-too)).
- macOS has no `timeout` and none of the shells some rows want, so start a long run detached on
  the VM and poll it.

```sh
scripts/mac-build.sh test     # sync, xcodegen, swift build + swift test on the VM
scripts/mac-build.sh app      # sync, xcodegen, xcodebuild, ad-hoc sign
```

`Apps/` needs a Mac only to compile and sign.

!!! warning "Run `signed` last"
    `scripts/mac-build.sh` rsyncs the tree to the VM with `--delete`, and there is no `build/` on
    the Linux side, so every run wipes the Mac's build directory.

### The testbed and CI

The testbed is twelve real SSH servers in Docker Compose, run **on the Mac that hosts the build
VM**, never on the Linux box. It exists to seed `SQ` rows and to answer questions the model
cannot; no ordinary run needs it. `testbed/README.md` has the account table, the `~/.ssh/config`
stanzas and the per-service smoke tests.

`.github/workflows/helper.yml` builds and tests the Rust crate and cross-compiles its targets.

## No decision under `Apps/`

`Apps/` is adapters: Apple types in, package types out, package types in, Apple calls out. A
reviewer should be able to read any file there in one sitting and find no branch worth testing.

| Target | Files | Lines | What is in it |
|---|---|---|---|
| `Apps/Agent` | 10 | 2,049 | the three roles, the XPC listener and services, the IOKit/`NWPathMonitor`/`CGEventSource`/`SMAppService`/`launchctl` adapters, `ReplicaControlling` over `NSFileProviderManager` |
| `Apps/FileProvider` | 5 | 979 | [the extension](extension.md): `NSFileProviderReplicatedExtension`, the enumerator and observer adapters, `NSFileProviderItem` over an `ItemView`, the `NSXPCConnection` half |
| `Apps/CLI` | 8 | 2,654 | argument parsing, output formatting, the XPC client |
| `Apps/Askpass` | 1 | 97 | one prompt relayed to the agent |

A new rule the extension follows belongs in `ProviderCore` with a scenario. A new rule the agent
follows belongs in `AgentRuntime` with a scenario. Nowhere else.

`Packages/SSHDriveCore` holds `Logging`, `XPCProtocols`, `XPCInterfaces`, `Config`, `Index`,
`SFTP`, `Secrets`, `SSHProcess`, `AgentCore`, `ProviderCore`, `AgentRuntime`,
`AgentRuntimeTestSupport`, `SystemModel` and `ServerModel`. All of it builds and tests on Linux.
`XPCInterfaces` (the `@objc` NSXPC protocols and the configured `NSXPCInterface` whitelists,
linked only by the four app targets) has `#if canImport(Darwin)` file bodies and compiles to
nothing off Darwin.

## The seams

### The extension's (`ProviderCore`)

Everything `Apps/FileProvider` would otherwise decide is in `ProviderCore`: the two enumerators,
the working-set change path and its fallback, the reader store and its readiness rule, item
construction, the trash contract, error selection and the two Finder actions. It sits behind
platform-free protocols:

| Name | What it is |
|---|---|
| `ProviderFailure` | an enum of every answer the extension may give: `.serverUnreachable`, `.noSuchItem`, `.cannotSynchronize`, `.syncAnchorExpired`, `.filenameCollision`, `.notAuthenticated`, `.insufficientQuota`, `.nonEvictable`, `.featureUnsupported`, `.deletionRejected`, `.excludedFromSync`. Every rule about *which error* is a rule about this type |
| `EnumerationObserving` | mirrors `NSFileProviderEnumerationObserver` |
| `ChangeObserving` | mirrors `NSFileProviderChangeObserver` |
| `ProviderEnumerating` | what `ContainerEnumeration` and `WorkingSetEnumeration` implement |
| `AgentChannel` | the extension's whole view of the agent. Two implementations: the NSXPC proxy in `Apps/FileProvider`, and `SystemModel.ModelAgent`, which answers over a real index database |
| `ReaderStoring` | the read-only WAL index reader, as `IndexReaderStore` implements it |
| `ProviderClock` | `now()`, injected |
| `ProviderDomainSignalling` | the signals the extension raises back at the system |

Apple's identifiers, capability bits, `fileSystemFlags` bits, `changedFields` bits, content policy
and error codes are mirrored as `ProviderItemIdentifier`, `ProviderSyncAnchor`,
`ProviderCapabilities`, `ProviderFileSystemFlags`, `ProviderItemFields` and
`ProviderContentPolicy`, so `AgentCore` and `ProviderCore` need no `import FileProvider`.

A mirror that drifted would be silent: the adapter keeps compiling and the Linux suite keeps
passing. `Tests/ProviderCoreTests/MirroredProviderConstantsTests.swift` and
`Tests/AgentRuntimeTests/MirroredAgentConstantsTests.swift` are one assert per constant against
Apple's own, compiled only where Apple's frameworks exist. They are the reason the suite also runs
on the Mac.

### The agent's (`AgentRuntime`)

`LocationRuntime` and its extensions, `DomainManager`, `ChangeDetector`, `CacheEvictor`,
`IndexReconcile`, `ReconnectingTransport` and its gate, `SSHBackedTransport`, the channel budget,
the helper's deployment and stream, the collect connection and both command handlers live in
`AgentRuntime` behind fifteen protocols:

| Protocol | Darwin implementation (`Apps/Agent`) | Linux implementation |
|---|---|---|
| `ReplicaControlling` | `FileProviderReplica` over `NSFileProviderManager` | `FakeReplica` |
| `SecretsStore` | the keychain store (`Security`) | `InMemorySecretsStore` |
| `LoginItemControlling` | `SMAppService` | `FakeLoginItem` |
| `LaunchdControlling` | `launchctl print` polling | `FakeLaunchd` |
| `PowerObserving` | IOKit, `IOAllowPowerChange` | `ScriptedPower` |
| `NetworkPathObserving` | `NWPathMonitor` | `ScriptedNetwork` |
| `PresenceReporting` | `CGEventSource` + `CGSessionCopyCurrentDictionary` | `ScriptedPresence` |
| `ScreenLockObserving` | the `com.apple.screenIsUnlocked` notifications | `ScriptedScreenLock` |
| `PeerIdentifying` | `PeerExecutable` + `SecStaticCode` | `ScriptedPeers` |
| `IndexReaderPeering` | the extension connection table | `RecordingReaderPeers` |
| `BundleInspecting` | quarantine xattr, bundle path, the executable vnode watch | `FakeBundle` |
| `KeychainDiagnosing` | the `OSStatus` round trip `doctor` reports | scripted |
| `TransportLauncher` | spawns `/usr/bin/ssh` | `FakeTransportLauncher`, or the real launcher with `ServerModel.FakeSSH` installed at `SSHProcess.sshBinaryPath` |
| `AgentEndpoint` | the NSXPC listener and `exit` | `RecordingEndpoint` |
| `AgentClock` | the system clock | `VirtualAgentClock` |

Two protocols sit beside the fifteen: `TerminalRelaying` (the CLI as the collect connection sees
it, one note and one prompt; `ScriptedTerminal` off Darwin) and `LiveConnection` (an
`SFTPTransport` the gate hands out or does not).

Details that matter when writing a scenario:

- `AgentClock` answers `now()` (wall clock, what the schedules are in), `uptime()` (monotonic,
  what the breaker's backoff is in) and `sleep(seconds:)`, so a scenario drives both readings
  together.
- `AgentEndpoint.terminate(status:)` does not return `Never`: the real one calls `exit`, the
  harness records the status, and `P4` asserts that SIGTERM exits 0.
- The seams are one value, `AgentEnvironment`, and `DomainManager` is constructed with it rather
  than reading singletons. That is what lets one process run two agents.
- `DomainManager.shared` still exists for the XPC command layer, which is reached from an object
  made per connection and has nothing else to hold. A scenario binds its own through
  `AgentCommandContext`, a task local, for the duration of one call.

`AgentRuntimeTestSupport` is the in-memory half: the fakes above plus `AgentHarness`, which gives
a scenario an `AgentEnvironment` it can drive, a `DomainManager` on it, a real SQLite index and a
temporary directory standing in for the group container. `Config.GroupContainer` is process-wide,
so the harness installs its locator on set-up and puts it back on tear-down, and the suites that
use it are `.serialized`.

## `SystemModel`

A simulated fileproviderd, Finder and launchd. It drives `ProviderCore` through the protocols
above exactly as the real one drives `Apps/FileProvider`, and behaves the way macOS was measured
to behave, with the version's quirk table deciding every difference.

The agent on the other side is `ModelAgent`: a scripted `AgentChannel` whose answers come from a
real `IndexWriter` on a real SQLite file. "An index with rows the replica lacks" means real rows,
and the extension's reader reads the same file. Only two things are scripted: whether the agent is
reachable, and what it answers to `indexReady`.

```swift
let harness = try ScenarioHarness(macOS: .v26_4)
try harness.serverCreates("note.txt")
let domain = try harness.addDomain()   // fileproviderd creates it and launches a provider
domain.openFolder()                    // one enumerateItems, ever
harness.clock.advance(60)              // the driven clock; nothing sleeps
XCTAssertEqual(harness.finderListing(), ["note.txt"])
```

| Part | What it simulates |
|---|---|
| `FileProviderD` | the replica (a tree of items with `isDownloaded`, size, versions, xattrs, `tagData`, content policy and pending state), the domain list, the working-set change stream, the sync-anchor bookkeeping, the pending-operation queue with its retry schedules, the error throttler, the download scheduler with its concurrency ceiling, and the trash node. It calls `ProviderCore` exactly as fileproviderd calls the extension, including launching a fresh provider instance for every working-set signal |
| `Finder` | the user: `open`, `read`, `openAtOnce`, `create`, `symlink`, `duplicate`, `save` (the atomic-save shape), `rename`, `chmod`, `tag`, `setExtendedAttribute`, `delete`, a `walk` answered from the replica that never reaches the extension, and `contextMenu(for:)`, which evaluates an action's activation rule the way `fileproviderctl evaluate` does |
| `Launchd` | the agent job, `RunAtLoad`, `KeepAlive`/`SuccessfulExit`, SIGTERM, the login-item record, `unregister`'s asynchrony and the launch-constraint window, bundle replacement, quarantine and the plugin registration that depends on it |

`VirtualClock` is the only clock in the model. `advance` moves time, releases whatever the
simulated schedulers owe, and returns when everything queued has run. There is no real sleeping
in the suite.

### Quirks and versions

Every behaviour the model implements is keyed to an `MQ-###` id from
[the macOS quirk catalogue](../quirks/macos.md); a version whose table says otherwise gets the
other behaviour.

```swift
public struct Quirk {
    public let id: QuirkID                   // "MQ-005"
    public let statement: String
    public let measurements: [QuirkMeasurement]   // versions, value, source
}
```

`QuirkTable(for:)` resolves each id to the value measured nearest that version and **refuses to
resolve an id with no measurement covering it**. A scenario that depends on an unmeasured quirk on
a supported version fails loudly with the id rather than quietly taking someone's guess.

`MacOSVersion` has two columns, `26.4` and `26.6`, identical unless a quirk says otherwise. macOS
14 and 15 are the supported minimum and nothing has been measured on either. Every empty cell in
the catalogue is that work item, and a scenario reaching for one of those columns fails rather
than guesses.

Where a value was taken once, or bracketed rather than measured, the rule that reads it and the
catalogue row both carry a `confidence:` note. Five do:

- the window in which an eviction straight after a `modifyItem` reply is refused (`MQ-017`)
- the single deferred atime advance (`MQ-022`)
- the reading that the dividing line in `MQ-029` is a new container rather than a new item
- the unpin settle window (`MQ-034`)
- the length of the window `unregister()` leaves open (`MQ-063`)

## `ServerModel`

The remote half: a whole SSH/SFTP server universe in process, plus the parts that are honest to
run for real on Linux.

### `ServerProfile`

One value describing a server: `sftp` implementation, the advertised extension list in order,
`findFlavour`, `loginShell`, `forceCommand`, `maxSessions`, `sessionGrouping`,
`clientAliveInterval`, `reapsOrphans`, `clockOffset`, `umask`, `caseInsensitive`,
`renameOverwrites`, `hasSHA256Sum`, `hasMkfifo`, `unameSM`, `identificationString`, `auth`, and
the `quirks` list naming the `SQ-###` rows it carries.

There are twenty-one constants:

- the twelve testbed services
- five account variants of them that behave differently: `debianPassword`,
  `debianKeyOrPassword`, `debianBackgroundHolder`, `debianForceCommand`, `debianExternalSFTPQuiet`
- the owner's own two servers, `ownerDebian` and `ownerTailscale`
- two we have no access to and model anyway, `freeBSD` and `synologyDSM`

The extension sets are exact, because `sshdrive status` reads them. Go `pkg/sftp` advertises
exactly `hardlink@openssh.com`, `posix-rename@openssh.com` and `statvfs@openssh.com`; OpenSSH's
own server adds `fsync`, `lsetstat`, `limits`, `expand-path`, `copy-data`, `home-directory` and
`users-groups-by-id`.

### The three stand-ins

`FakeSFTPServer` and `FakeExecChannel` speak the same `SSHProcess.ByteStream` a mux client's stdio
does, so `SFTPClient`, `RemoteScript`, the sweep script, the sentinel, the heartbeat wrapper and
the helper's NDJSON reader all run unmodified.

**`FakeSFTPServer`** is a real SFTP v3 wire server over a `ByteStream` pair. It speaks the
protocol, not a mock of it:

- `SSH_FXP_VERSION` with the profile's extension list
- status classes and no errno, so `ENOSPC`/`EEXIST`/`ENOTEMPTY`/`EXDEV` all arrive as a bare
  `FAILURE`
- OpenSSH's reversed `SSH2_FXP_SYMLINK` argument order
- an `opendir` that follows a symlink, and a `readdir` carrying attributes but no link target
- `limits@openssh.com` values, `posix-rename` present or absent, and a plain `rename` that does or
  does not overwrite
- `ETXTBSY` on a write over a running executable, `mkdir` attributes filtered by the umask, and
  case folding

`SFTP.FakeTransport` remains the fast in-memory double for tests that do not care about the wire.

**`FakeExecChannel`** is an exec channel whose remote end is **a real POSIX shell on the box
running the tests**. It picks the profile's shell, prepends the profile's rc-file noise, applies
the `ForceCommand` refusal sentence where the profile has one, enforces `MaxSessions`, and models
the session's process-group policy with a real `setsid` or a shared pgid, so `kill -TERM 0` really
does or does not reach a bystander. A scenario needing a shell the box does not have (`fish`,
`tcsh`, `zsh`) skips with a named reason.

The shell scripts are tested against real shells because three of the worst bugs this project has
had lived there: the `;;` dash rejects, the `{ … }` group the heartbeat reader would otherwise eat
off its own stdin, and the `printf "\0<sentinel>"` that ate its own sentinel.

**`FakeSSH`** is a small executable the package builds, installed at `SSHProcess.sshBinaryPath` as
the `TransportLauncher`'s "ssh", so `SSHInvocation`'s argv assembly, the spawn,
`ExitClassification` and `ControlSocket` run for real. It:

- binds a real `ControlPath` socket and answers `-O check` and `-O exit`
- honours or ignores `ControlPersist`
- prints the measured stderr sentences with CRLF line endings, and `remote software version …`
  only at `DEBUG1` and above
- invokes `SSH_ASKPASS` with the measured prompt strings, trailing spaces included
- applies OpenSSH's readconf first-setting-wins rule, and percent-expands a `ProxyCommand` before
  handing it to `/bin/sh`
- exits 255 with nothing on stderr when its remote command was killed by a signal

### The box is a seam too

`ServerModel.HostTools` measures once per process what the machine running the suite can do. A
scenario that meets one of those bounds skips with the sentence it returns: a skip naming the
platform fact, never a silent `#if`. Three bounds apply:

| Bound | Rule |
|---|---|
| the local `find` | probed by what it accepts, not what it prints (`SQ-081`, the rule `SQ-002` states for a server). A row needing *a* `-cmin` runs against GNU findutils on Linux and BSD `find` on a Mac; only a busybox profile is shimmed |
| non-UTF-8 names | the filesystem is asked whether it will hold one (`SQ-080`). APFS will not, so `H7`'s real-`find` half is Linux-only; its `partitionRoots` and SFTP-wire halves run everywhere |
| `PATH_MAX` and `sockaddr_un.sun_path` | read from the box, not written out (`SQ-085`). A harness tree deep enough to outrun a channel's 4 MB buffer is over the Darwin limit at Linux's dimensions, and every `open` then fails silently |

`FakeSSH` also tells `ControlSocket` what the kernel will call a running stub. The stub is a shell
script named `ssh`; Linux takes a process's short name from the script and XNU from the
interpreter binary, and macOS launch constraints `SIGKILL` a copy of any system shell, so there is
no binary to point a shebang at (`SQ-082`). `ControlSocket.masterProcessName` is the seam, and
`install()` sets it to a name measured from a probe script that prints before it sleeps.

The harness suppresses one artifact rather than asserting around it. A shell prints
`Killed`/`Terminated` on its own stderr when a foreground child dies by a signal, and dash writes
it to the *command's* redirected stderr (`SQ-084`), while `SQ-011` says a signal-killed remote
command prints nothing at all. `FakeSSH` hands the session its real stderr on fd 4 and points its
own at `/dev/null`.

### Process-wide state in a concurrent suite

`swift test` runs the swift-testing suites concurrently with XCTest in one process, so anything
installed process-wide is shared. Two rules follow:

- A scenario that sweeps or kills by prefix passes the directory it acts on.
  `ControlSocket.sweepOrphans(in:)`, `liveMasterPIDs(in:)` and `killStrayMasters(in:)` default to
  the real `$TMPDIR`, which is the blast radius `agent stop` needs; a test passes one of its own.
- A suite that installs `SSHProcess.sshBinaryPath` (which decides which stub every `ssh` in the
  process is) is `.serialized`, and its bed stops its agent before putting the path back.
  Otherwise a `DomainManager` handed to a detached task outlives its bed, goes on reconnecting on
  the breaker's schedule and dials the next scenario's stub.

## The quirk catalogue

`docs/quirks/` is the inventory of measured behaviour: [macos.md](../quirks/macos.md) (80 rows)
and [servers.md](../quirks/servers.md) (82). [The catalog's README](../quirks/README.md) has the
row format and the steps that turn a measurement into a model rule and a scenario.

`MQ` rows are keyed to a macOS version. `SQ` rows are keyed to a testbed service or a real server,
not to an OS version, so a new testbed image is the same kind of work as a new macOS and wants the
same walk.

The models name the ids they read: `SystemModel`'s `Quirks.swift` and `QuirkCatalogue.swift`,
`ServerModel`'s `ServerQuirks.swift`. Two tests keep the halves from drifting:

- `QuirkCatalogueTests` asserts that every id the macOS model resolves is a row of
  [macos.md](../quirks/macos.md) and that every id resolves on both columns.
- `ServerProfileScenarios` asserts that every id `ServerModel` implements is a row of
  [servers.md](../quirks/servers.md) and that every profile cites only implemented ids.

**The VM measures; it never proves.** A VM session that ends without a catalogue row, a model rule
and a green Linux suite has not finished.

### Adding a macOS version

1. Add the version to `MacOSVersion`.
2. Measure on a VM of that version against the testbed.
3. Walk **every** row of [macos.md](../quirks/macos.md) and record a value: confirmed, changed, or
   not measured. Not-measured is a legitimate answer and shows as an empty cell.
4. Walk every row of [servers.md](../quirks/servers.md) too where the session touched a server.
5. For each changed value, add a measurement and let the model branch on it.
6. Mark any value taken once, or bracketed, with a `confidence:` note in both the row and the rule
   that reads it.
7. `swift test --filter QuirkCatalogueTests` checks that no id is in the model and missing from
   the catalogue.
8. `swift test` on Linux, green.
9. Update [the catalog README](../quirks/README.md)'s supported-versions table, and
   [the platform page](platform.md) if the minimum moved.

## Scenarios

A scenario is a numbered regression: a setup, an action and an assertion, named after the failure
it defends against. Ids are stable for ever - a scenario is never renumbered, only retired with a
reason - and the quirk rows cite them.

Scenarios live beside the module they exercise:

| Where | What |
|---|---|
| `Tests/SystemModelTests` | the ones that need a simulated macOS |
| `Tests/AgentRuntimeTests` | the agent's own decisions |
| `Tests/ServerModelTests` | the wire and the shells |
| the module's own suite | the rest |

There are 143 ids in fifteen families, and 126 of them are named in `Tests/`. The seventeen that
are not are the outstanding work: `C3`-`C6`, `D7`, `D8`, `E1`, `E4`-`E6`, `F3`, `G7`, `K8`, `L2`,
`M1`, `P6`, `P7`. Several of the behaviours behind them are covered by a unit test that does not
name the id.

| Family | Covers | Design |
|---|---|---|
| A | the working set, anchors and enumeration | [the extension](extension.md), [the index](item-index.md) |
| B | trash | [names and attributes](names-and-attributes.md) |
| C | extension lifecycle and XPC | [the extension](extension.md) |
| D | writes, conflicts, atomicity | [writes](writes.md) |
| E | the index | [the index](item-index.md) |
| F | offline, the breaker, reconnection | [offline behaviour](offline.md) |
| G | eviction and pinning | [eviction](eviction.md), [pinning](pinning.md) |
| H | change detection | [change detection](change-detection.md), [the root set](root-set.md) |
| J | remote execution and the helper | [security](security.md), [change detection](change-detection.md) |
| K | transport and `ssh` | [SSH process management](ssh.md) |
| L | paths, names and attributes | [names and attributes](names-and-attributes.md), [security](security.md) |
| M | symlinks | [symlinks](symlinks.md) |
| N | the capability report and probes | [the CLI](cli.md) |
| P | packaging and lifecycle | [packaging](packaging.md) |
| Q | `add`, askpass and the collect connection | [secrets and host keys](secrets.md), [the location model](locations.md) |

### A - the working set, anchors and enumeration

| Id | Name |
|---|---|
| A1 | Empty change set at the held anchor |
| A2 | The `.serverUnreachable` storm |
| A3 | Reader-not-ready on a fresh instance |
| A4 | `currentSyncAnchor` must not invent 0 |
| A5 | Anchor expiry reports once and sweeps once |
| A6 | A folder is enumerated once, ever |
| A7 | A new sibling needs a working-set signal |
| A8 | A 60 s `enumerateItems` is not taken away |
| A9 | The working set enumerates no items |

### B - trash

| Id | Name |
|---|---|
| B1 | The `.Trash` materialize loop |
| B2 | `supportsSyncingTrash = false` alone is not enough |
| B3 | A `.Trash` create under the root is refused |

### C - extension lifecycle and XPC

| Id | Name |
|---|---|
| C1 | Disconnect-in-invalidation |
| C2 | A reader error is `.serverUnreachable` |
| C3 | The listener picks the interface by peer |
| C4 | A stranger is dropped |
| C5 | An agent error survives the trip |
| C6 | A stalled replica call must not wedge the agent |

### D - writes, conflicts, atomicity

| Id | Name |
|---|---|
| D1 | A `modifyItem` reply is believed |
| D2 | The conflict copy evicts, retried |
| D3 | `.filenameCollision` only when the name frees |
| D4 | A pending edit on a deleted item |
| D5 | The guard holds pending items and their ancestors |
| D6 | In-flight paths are invisible to change detection |
| D7 | The conflict check reads `generation` |
| D8 | A pending upload survives a bundle replacement |
| D9 | An atomic save keeps the identifier |
| D10 | The temp+rename upload restores mode and mtime |
| D11 | The stale temp sweep takes only our prefix |
| D12 | Both `fetchContents` failures are reversible |

### E - the index

| Id | Name |
|---|---|
| E1 | Nested transactions |
| E2 | A listing is one transaction, holds the writes alone, and compiles a constant number of statements |
| E3 | Sorted keys in the attributes blob |
| E4 | A local-only row survives |
| E5 | The reconcile always clears its flag |
| E6 | `held.dir` follows a rename |
| E7 | A ten-thousand-entry first listing |

### F - offline, the breaker, reconnection

| Id | Name |
|---|---|
| F1 | `signalErrorResolved` is the only flush |
| F2 | No system retry for a fetch |
| F3 | A dead connection is retried once |
| F4 | A queued write is re-offered for ever |
| F5 | A call waits for the attempt in flight |
| F6 | Sleep drops, wake reconnects |
| F7 | The reconnect re-opens the helper stream |
| F8 | An outage is not a tier verdict |
| F9 | Repeated down/up cycles converge |
| F10 | The authentication deadline re-arms once per trigger |
| F11 | The path gate fails fast and spawns nothing |

### G - eviction and pinning

| Id | Name |
|---|---|
| G1 | atime is not in the TTL's `max` |
| G2 | `evict --all` falls back to a walk |
| G3 | `-2008` says nothing about why |
| G4 | Policy refuses, not the capability |
| G5 | An explicit lazy child wins |
| G6 | A pin on an unseen path |
| G7 | A pin change rewrites descendants |
| G8 | Six fetches, and the seventh |
| G9 | `evictItem` is recursive |
| G10 | The transfer scheduler |
| G11 | Pins export and import |
| G12 | The agent's own `stat` under its mount is not gated |
| G13 | Finder owns Download Now and Remove Download |
| G14 | Our actions are one of a pair, top level, never on the sidebar |

### H - change detection

| Id | Name |
|---|---|
| H1 | busybox `find --version` exits 0 |
| H2 | `-cmin`/`-printf` refused on busybox |
| H3 | `-mmin` misses a ctime-only change |
| H4 | The window is elapsed time |
| H5 | A truncated sweep stores nothing |
| H6 | Every root is spelled `./name` |
| H7 | A non-UTF-8 root goes to tier 0 |
| H8 | The rotation and the caps |
| H9 | A CLI command is a touch |
| H10 | A cycle that eats its interval |
| H11 | The mass-deletion guard's thresholds |

### J - remote execution and the helper

| Id | Name |
|---|---|
| J1 | The wrapper names `-$$`, never `0` |
| J2 | A bare background child survives a kill |
| J3 | `ClientAliveInterval` does not help |
| J4 | The sentinel's NUL is its own `printf` |
| J5 | One `{ … }` group ending in `exit` |
| J6 | The reader's descriptor and the EXIT trap |
| J7 | The relay must not make `;;` |
| J8 | The helper is fed through a FIFO |
| J9 | `--version` digests its own executable |
| J10 | Writing over a running helper |
| J11 | A stale relay FIFO |
| J12 | Tier 2 needs a held channel |
| J13 | The exec channel dies 255 with no stderr |
| J14 | The login-shell snapshot, per shell |

### K - transport and `ssh`

| Id | Name |
|---|---|
| K1 | `ProxyCommand` before `ProxyJump=none` |
| K2 | `%h`/`%p` doubled per level |
| K3 | Mux client options |
| K4 | The master's shape |
| K5 | The orphan sweep takes only sockets |
| K6 | `agent stop` takes the masters |
| K7 | The host-key question has no hint |
| K8 | A passphrase prompt truncates |
| K9 | stderr says nothing about a key agent |
| K10 | The collect connection runs to 300 s |
| K11 | CRLF stderr |
| K12 | The server is identified |
| K13 | A dying connection records no budget |
| K14 | An abrupt loss makes the cached budget suspect |

### L - paths, names and attributes

| Id | Name |
|---|---|
| L1 | `opendir` follows a symlink |
| L2 | `RelativePath` refuses escapes |
| L3 | `displayName` is the bare nickname |
| L4 | Tags travel as `tagData` |
| L5 | The system filters xattrs |
| L6 | `.DS_Store` never arrives |
| L7 | A case collision is hidden |
| L8 | Locked by derivation |

### M - symlinks

| Id | Name |
|---|---|
| M1 | The lexical containment check |
| M2 | A `readlink` per link |
| M3 | A refused `ln -s` is a sync error |
| M4 | A real link, and a dangling one |

### N - the capability report and probes

| Id | Name |
|---|---|
| N1 | Never blame a server for our state |
| N2 | A cached probe keeps its extensions |
| N3 | The `MaxSessions` probe |
| N4 | A shell-less account |
| N5 | The report names the server, and `fsync`/`limits` are server facts |
| N6 | `status` never touches the wire |
| N7 | Free space is taken at probe time and kept |
| N8 | The state word comes from the gate |
| N9 | `status` reads the index through its own reader |
| N10 | A stuck location costs its own row, not the report |
| N11 | A rebuild in progress, and an index that is not there yet |

### P - packaging and lifecycle

The family whose ground truth is a Mac. Each asserts the state machine on Linux; the fact behind
it is a runbook item.

| Id | Name |
|---|---|
| P1 | The login item after a replacement |
| P2 | `unregister` waits for launchd |
| P3 | A quarantined bundle registers no plugin |
| P4 | SIGTERM exits 0, and `agent stop` takes every master |
| P5 | `add(domain)` 4099 after landing |
| P6 | Stranded domains are removed |
| P7 | The profile names the signing certificate |
| P8 | A nickname renames in place |
| P9 | `add` waits for the first deployment |
| P10 | A launch repairs a constrained registration |
| P11 | A launch rebuilds a stale LaunchServices record |

### Q - `add`, askpass and the collect connection

Each drives the shipping `add` end to end, and nothing between the CLI's arguments and the server
is a stub of ours:

- `FakeSSH` at `SSHProcess.sshBinaryPath` answers `ssh -G`, raises the real prompt strings and
  binds a real control socket.
- An askpass-shaped program, with a file mailbox in place of the XPC connection, hands each prompt
  to the real broker.
- The mount that follows runs the real SFTP transport over `FakeSFTPServer` on a real SFTP v3
  wire.

| Id | Name |
|---|---|
| Q1 | Key auth prompts for nothing |
| Q2 | A password is relayed, stored on the resolved host, and asked for once |
| Q3 | A `ProxyJump` chain is keyed per hop |
| Q4 | Keyboard-interactive shares the plain password key |
| Q5 | The host-key question, answered no then yes |
| Q6 | A wrong password stores nothing |
| Q7 | A bad remote path rolls back |
| Q8 | The askpass token lifecycle and prompt classification |
| Q9 | The two-step collect connection |

## What stays a manual check

These stay VM runbook items. They are listed so that nobody mistakes a green Linux suite for proof
of them.

| Area | What only a Mac can show |
|---|---|
| Drawing | what Finder puts on the screen: the contextual menu's entries and their order, the badge's position, the dataless cloud badge, the static progress ring, the absence of a cancel control, the sidebar's composed label, the "downloaded from the Internet" dialog. The model evaluates activation rules and declarations; it cannot see pixels |
| Code signing, Gatekeeper, AMFI, notarization | that a provisioning profile must name the certificate the bundle is signed with; that an ad-hoc signature carrying `keychain-access-groups` is killed at exec; that `com.apple.application-identifier` on the agent makes launchd refuse it; that a stapled but unsigned DMG is rejected on the download path; that `notarytool store-credentials` cannot be run over ssh |
| LaunchServices, PlugInKit, `SMAppService`, launchd | the model reproduces the state machine, because that is what our code reasons about. Whether LaunchServices really declines to register a quarantined bundle's plugins, and whether a fresh user really needs no visit to System Settings, are measurements |
| TCC | that an agent's `stat` of its own domain's mount is allowed as `kTCCServiceFileProviderDomain` and draws no prompt |
| The real keychain and key agents | the data-protection keychain under an access group, 1Password and Secretive behind `IdentityAgent`, Apple's `UseKeychain`, a FIDO key's user-presence notice and PIN prompt, and the 60 s deadline firing against a touch |
| Local Network privacy | the prompt itself |
| Timing, throughput and scale | the model reproduces the shape - that the rotation bounds a cycle, that `-cmin` costs a `stat` per entry - never the milliseconds |
| The system's own schedulers | that the background-download scheduler takes 8-90 s to start an eager fetch on an idle headless Mac, and that a headless Mac throttles the working-set fetch at all. The model runs them instantly; a latency claim needs a Mac somebody is using |
| IOKit power delivery | `IORegisterForSystemPower` registers on the VM, but the VM refuses `pmset sleepnow`, so that macOS actually delivers `kIOMessageSystemWillSleep` is unproven anywhere |
| Filesystem semantics | APFS's `relatime` behaviour, case-insensitive comparison of NFC against NFD, `XATTR_FLAG_SYNCABLE` at the kernel level, and whatever advances a materialized file's atime minutes after a fetch. The model encodes the observation, not the mechanism |
| Servers we do not have | a BSD *server*: FreeBSD's `sh`, FreeBSD kqueue and the helper's FreeBSD target (`aarch64-unknown-freebsd` cannot even be `cargo check`ed). A real Synology DSM box, its `sh` and its `max_user_watches`. armv7 hardware. The owner's own Tailscale server: a behaviour that reproduces on the testbed's `ts-ssh` is evidence about Tailscale SSH, not about that machine |
| Real Finder-driven saves | by Pages, Numbers, Keynote, Microsoft Office and Xcode, none of which are on the VM |

A real BSD `find` is not on this list: macOS's `/usr/bin/find` is one, and `H4` and `H7` exercise
the `.bsd` flavour against it when the suite runs on the Mac.
