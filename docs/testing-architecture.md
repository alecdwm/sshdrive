# Testing architecture: a Linux-isolated harness for measured macOS behaviour

**The principle, in the owner's words (2026-09-08):**

> "I would like as much of the testing as possible to be done in a way that encodes mocks
> measured/known macOS behaviour and then exercises the codebase against all known issues
> identified in the past. If future macOS releases cause breakage, we can then add their
> behaviour into the encoded mocks and thereby unit test across all supported macOS versions
> (and each one's quirks) without needing to spin up VMs and such. The tests should be able to
> run 100% isolated on a Linux box. We should only use the VM to seed the macOS mocks into the
> tests."

## 0. Why this document exists

Version 0.1.2 shipped a silent failure. The working-set enumerator answered
`.serverUnreachable` whenever its index reader was not ready; fileproviderd throttles a change
enumeration that keeps failing, and after 27 consecutive errors on one real domain it took the
domain's fetch-event stream out to a **47-minute** retry. Nothing synced down. `sshdrive status`
was green throughout, because nothing in it knows what fileproviderd thinks.

That bug was reachable in one line of a state machine, and it was not caught because the only
end-to-end checks this project has ever had are agent-run proofs on a macOS 26.4 VM: manual,
slow, one OS version, one person's afternoon, and never re-run. Meanwhile the package's 635
unit tests are green and none of them can see fileproviderd at all, because everything that
talks to the system lives under `Apps/`, which `swift test` never builds.

The fix is not more VM time. It is to move every decision into the package, express the
system's own behaviour as **data measured on the VM** rather than as an assumption in a
comment, and run the whole thing on Linux against a simulator of that data.

Three claims this architecture makes, and they are the acceptance criteria:

1. Every past failure in `docs/spikes/results.md` and DESIGN.md §13 has a numbered regression
   scenario that runs on Linux with no Mac, no VM and no network.
2. A new macOS version is a **new column in a quirk table**, not a new test. Its cost is one
   VM measuring session plus a set of table cells.
3. The VM measures. It never proves. A VM finding is not finished until it is a `docs/quirks/`
   entry, a `SystemModel`/`ServerModel` rule and at least one scenario.

## 1. Where we are today

```
Packages/SSHDriveCore/          builds on macOS only; swift test never sees Apps/
  Logging   XPCProtocols   Config   Index   SFTP   Secrets   SSHProcess   AgentCore
Apps/Agent/          ~10,000 lines, of which the great majority is decision, not I/O
Apps/FileProvider/   ~1,400 lines, all of it decision behind four Apple protocols
Apps/CLI/  Apps/Askpass/
helper/              Rust; already builds and tests on this Linux box
```

Measured on this box on 2026-09-08 with Swift 6.3.3 (`. ~/.local/share/swiftly/env.sh`):

```
$ swift build
error: emit-module command failed
Sources/Logging/Log.swift:2:8: error: no such module 'os'
```

**The package does not compile on Linux at all, and it fails at the very first module.** Every
other target depends on `Logging`, so nothing past it was even attempted. The Linux port is
therefore a walk: fix `Logging`, run `swift build` again, and the compiler names the next
Darwin-only import. From the source we already know what it will name:

| Module | Darwin-only | What it is |
|---|---|---|
| `Logging` | `import os` | `os.Logger`, `.public` privacy interpolation |
| `Index` | `import SQLite3` | Darwin's module for the same C library Linux has as `libsqlite3` |
| `Secrets` | `import Security` | `SecItemAdd`/`CopyMatching`/`Delete` in `SecretsStore.swift` |
| `Secrets` | `sysctl KERN_PROCARGS2` | `ProcessAncestry.swift`, the askpass argv read |
| `XPCProtocols` | `NSXPCInterface`, `@objc` protocols | `Interfaces.swift`, `AskpassProtocol.swift`, `CLIProtocol.swift` |
| `XPCProtocols` | `SecStaticCode` | `CodeRequirement.swift`, the peer requirement |
| `AgentCore` | `import FileProvider` | `ItemDerivation.swift`, `RowBuilder.swift` — capability and `fileSystemFlags` bitmasks |
| `SSHProcess` | `posix_spawn`, `S_IFSOCK` | portable; needs `#if canImport(Darwin)` around the imports only |
| `Config` | `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)` | `GroupContainer.swift`; not predicted, found once `Logging` compiled |

`IOKit`, `ServiceManagement`, `CoreGraphics`, `Network` and `FileProvider` proper appear only
under `Apps/`, which is the right place for them and where they stay.

**2026-09-08: the whole package is ported** (§8 steps 1.1 and 1.2). Every row of the table
above is closed and `swift build` and `swift test` run to completion on this box: **663 tests,
0 failures, 41 skipped** (the testbed-gated ones), against **667** on the Mac. Nothing under
`Packages/` needs Darwin any more; the walk continues at `Apps/`, which is step 1.3.

**2026-09-08, later: step 1.3 is done too.** `Apps/FileProvider` is five adapter files and
holds no decision; everything it used to decide is `ProviderCore`, and `SystemModel`'s
fileproviderd drives it on Linux. **697 tests here**, 41 skipped, and **706 on the Mac**
(the nine extra are the macOS-only mirrored-constant assertions), with all four Xcode
targets still building and signing.

**2026-09-08, later still: step 8 is done.** `Apps/Agent` went from 13,300 lines to
**ten adapter files, 2,009 lines**, none of which contains a branch worth testing;
everything it decided is `AgentRuntime`, behind the fourteen protocols of section 2.3.
Nothing under `Apps/` needs Darwin for a reason other than Apple's own types any more.

## 2. (a) The seams

The rule the whole architecture rests on: **nothing under `Apps/` may contain a decision.**
`Apps/` is adapters — Apple types in, package types out, package types in, Apple calls out —
and a reviewer should be able to read any file there in one sitting and find no branch worth
testing. Everything else moves into the package behind a named protocol.

`RelativePath`, `Index` and `AgentCore` keep their names, their contents and their public
surface. Two new logic modules and two new simulation modules are added.

### 2.1 New package modules

```
Packages/SSHDriveCore/Sources/
  Logging/          + LogFacade.swift            (os.Logger on Darwin, stderr elsewhere)
  XPCProtocols/     value types only, no @objc                      (done 2026-09-08)
  XPCInterfaces/    macOS-only: the @objc protocols and the NSXPCInterface whitelists,
                    referenced only from Apps/. The peer requirement stayed in
                    XPCProtocols: it is a string, and the SecStaticCode call that
                    applies it is in Apps/Agent                       (done 2026-09-08)
  ProviderCore/     everything Apps/FileProvider decides               (done 2026-09-08)
  AgentRuntime/     NEW: everything Apps/Agent decides
  SystemModel/      simulated fileproviderd + Finder + launchd, quirk-driven
                    (fileproviderd's enumeration and working-set half done 2026-09-08)
  ServerModel/      NEW: simulated ssh, sftp-server, shells and find flavours
```

### 2.2 The extension's seams (`ProviderCore`)

Today `Apps/FileProvider` is five files and all five are logic wearing an Apple coat. The
split:

| Today | Moves to | Left in `Apps/FileProvider` |
|---|---|---|
| `Enumerators.swift` (275 lines) | `ProviderCore/ContainerEnumeration.swift`, `ProviderCore/WorkingSetEnumeration.swift` | one `NSFileProviderEnumerator` adapter and the two observer adapters (done 2026-09-08; one adapter proved to be enough, because which enumerator a container gets is decided in `ProviderService.enumerator(for:)`) |
| `FileProviderExtension.swift` (523) | `ProviderCore/ProviderService.swift` — identifier mapping, the trash refusal, the working-set health counters, the reader/agent choice, error selection | `FileProviderExtension.swift`, an `NSFileProviderReplicatedExtension` that forwards each call |
| `IndexReaderStore.swift` (303) | `ProviderCore/ReaderStore.swift` unchanged but for the `import FileProvider` | nothing |
| `Item.swift` (111) | `ProviderCore/ItemView.swift`, a plain struct | `Item.swift`, an `NSFileProviderItem` over an `ItemView` |
| `AgentConnection.swift` (183) | the error table → `ProviderCore/ProviderFailure.swift` | the `NSXPCConnection` half |

Protocols, named:

- **`ProviderFailure`** — a platform-free enum of every answer the extension may give:
  `.serverUnreachable`, `.noSuchItem`, `.cannotSynchronize`, `.syncAnchorExpired`,
  `.filenameCollision`, `.notAuthenticated`, `.insufficientQuota`, `.nonEvictable`,
  `.featureUnsupported`, `.deletionRejected`, `.excludedFromSync`. Every rule in DESIGN.md
  about *which error* is a rule about this type, and today's bug is exactly a wrong value of
  it. The Apple mapping (`NSFileProviderError`, `NSCocoaErrorDomain/NSFeatureUnsupportedError`)
  is one function in `Apps/FileProvider`, covered by a macOS-only constants test.
- **`EnumerationObserving`** — `didEnumerate([ItemView])`, `finishEnumerating(upTo: PageToken?)`,
  `finishEnumerating(with: ProviderFailure)`. Mirrors `NSFileProviderEnumerationObserver`.
- **`ChangeObserving`** — `didUpdate([ItemView])`, `didDeleteItems([ItemIdentifier])`,
  `finishEnumeratingChanges(upTo: SyncAnchor, moreComing: Bool)`,
  `finishEnumerating(with: ProviderFailure)`. Mirrors `NSFileProviderChangeObserver`.
- **`AgentChannel`** — the extension's whole view of the agent: `indexReady`,
  `enumerateItems`, `enumerateChanges`, `enumerateWorkingSetChanges`, `item`, `fetchContents`,
  `fetchPartialContents`, `createItem`, `modifyItem`, `deleteItem`, `performAction`,
  `reportAnchorExpired`, `noteWorkingSetSucceeded/Failed`. Three implementations: the real
  NSXPC proxy (`Apps/FileProvider`), an in-process loopback onto `AgentRuntime` (the
  SystemModel's default, so scenarios exercise both halves at once), and a scripted stub.
- **`ReaderStoring`** — `stateName`, `changes(since:)`, `currentSequence()`, `item(for:)`,
  the existing `IndexReaderStore` surface minus the Apple types.
- **`ProviderClock`** — `now()`, injected, as `AgentCore`'s clock-taking types already do.

`AgentCore/ItemDerivation.swift` and `AgentCore/RowBuilder.swift` lose `import FileProvider`:
the capability and `fileSystemFlags` bitmasks become named constants in
`ProviderCore/ProviderCapabilities.swift` (`allowsReading = 1 << 0`, … `allowsEvicting`,
`allowsExcludingFromSync`) and `ProviderFileSystemFlags`. A macOS-only test target,
`AppleConstantsTests`, asserts each constant still equals Apple's, which is the only thing
that could drift and is exactly one assert per constant.

### 2.3 The agent's seams (`AgentRuntime`)

Moves into `AgentRuntime`, with their `import FileProvider` replaced by `ReplicaControlling`:
`LocationRuntime.swift` (1,743), `LocationRuntime+ChangeDetection.swift` (739),
`LocationRuntime+Pinning.swift` (433), `IndexReconcile.swift` (846), `ChangeDetector.swift`
(588), `ReconnectingTransport.swift` (663), `CacheEvictor.swift` (325), `ChannelBudget.swift`
(331), `SSHBackedTransport.swift` (434), `HelperDeployer.swift` (306), `HelperStream.swift`
(297), `HelperCleanup.swift`, `CollectConnection.swift` (281), `ExtensionPeers.swift`,
`CallJournal.swift`, `ConfigAccess.swift`, `Deadline.swift`, `AgentLifecycle.swift`'s policy
half, `LocationCommands.swift` (932) and `ControlCommands.swift` (1,180) as command handlers
over the protocols, and `DomainManager.swift` (627) split into `AgentRuntime/DomainRegistry`
(the policy: which domains should exist, stranded-domain removal, shutdown order) and the
`NSFileProviderManager` calls behind the protocol.

Stays in `Apps/Agent` as an adapter: `main.swift`, `ListenerDelegate.swift`,
`AgentService.swift`, `AskpassService.swift`, `ReplicaAccess.swift`, `ReplicaEnumerators.swift`,
`PowerEvents.swift`, `AgentPresence.swift`, `PeerExecutable.swift`, `HandleSink.swift`,
`SpikeHooks.swift`, `TransportDebug.swift`, plus new one-file adapters for the login item, the
keychain and launchd.

**As built**, `Apps/Agent` is ten files and 2,009 lines: `main.swift` (the three roles and
nothing else), `ListenerDelegate.swift`, `AgentService.swift`, `AskpassService.swift`,
`CLIRelay.swift`, `ExtensionPeers.swift`, `PeerExecutable.swift`, `AgentLifecycle.swift`
(the two dispatch sources; what they decide is `AgentRuntime.AgentLifecycle`),
`FileProviderReplica.swift` (`ReplicaControlling` over `NSFileProviderManager`, merging what
`ReplicaAccess`, `ReplicaEnumerators` and `SpikeHooks` were) and `SystemSeams.swift` (IOKit
power, `NWPathMonitor`, `CGEventSource` presence, the two distributed notifications,
`SMAppService`, `launchctl print`, the bundle, the keychain diagnostics and the endpoint).
`HandleSink` and `TransportDebug` moved into the package after all - both are pure
Foundation, and `HandleSink` is called from `LocationRuntime`. `SSHBackedTransport` moved
too, with `SSHTransportLauncher` beside it: everything under it was already platform-free in
`SSHProcess`, and what stands in for a server on Linux is the *binary*, not this code.

Protocols, named:

| Protocol | Apple implementation (stays in `Apps/`) | Linux implementation |
|---|---|---|
| `ReplicaControlling` | `ReplicaAccess`, `ReplicaEnumerators`, `DomainManager`'s `NSFileProviderManager` calls | `SystemModel.FileProviderD` |
| `SecretsStoring` | `KeychainSecretsStore` (`Security`) | `InMemorySecretsStore` |
| `LoginItemControlling` | `SMAppService` adapter | `SystemModel.Launchd` |
| `LaunchdControlling` | `launchctl print` polling | `SystemModel.Launchd` |
| `PowerObserving` | `PowerEvents` (`IOKit`, `IOAllowPowerChange`) | `SystemModel.Power` |
| `NetworkPathObserving` | `NetworkPathGate` (`NWPathMonitor`) | `SystemModel.Network` |
| `PresenceReading` | `AgentPresence` (`CGEventSource`, `CGSessionCopyCurrentDictionary`) | scripted idle/lock values |
| `ScreenLockObserving` | `ScreenLockObserver` (`com.apple.screenIsUnlocked`) | scripted |
| `PeerIdentifying` | `PeerExecutable` + `SecStaticCode` | scripted peer identities |
| `ProcessAncestryReading` | `sysctl KERN_PROCARGS2` | scripted argv |
| `BundleInspecting` | quarantine xattr, bundle path, the executable vnode watch | scripted |
| `TransportLauncher` | spawns `/usr/bin/ssh` | `ServerModel.FakeSSH` |
| `AgentEndpoint` | the NSXPC listener | in-process loopback |
| `Clock` | the system clock | a driven clock |

Every one of these is small — most are three to six methods — because the decisions they used
to carry have moved above them.

**As built (2026-09-08), with four differences from the table above and three additions.**

- The presence seam is **`PresenceReporting`**, not `PresenceReading`: `AgentCore` already
  owns a *value* called `PresenceReading` - section 4.2's two readings - and a protocol of
  the same name in a module that imports it is ambiguous at every use.
- The clock is **`AgentClock`**, not `Clock`, which is a standard-library protocol. It
  answers `now()` (wall clock, what the schedules are in), `uptime()` (monotonic, what the
  breaker's backoff is in) and `sleep(seconds:)`, so a scenario drives both together.
- `ProcessAncestryReading` needed nothing: `Secrets.ProcessAncestry` was already a protocol
  with a `/proc` implementation off Darwin (step 1.2), and `SecretsStoring` is the
  `Secrets.SecretsStore` that step made platform-free.
- `AgentEndpoint.terminate(status:)` does **not** return `Never`: `P4` asserts that SIGTERM
  exits *0*, and no assertion can be made about a process that is gone. The real one calls
  `exit`; the harness records the status.
- **`IndexReaderPeering`** is a fifteenth, split out of `ExtensionPeers`, which section 2.3
  listed on both sides of the line: the `NSXPCConnection` table stays in `Apps/Agent`, and
  the "ask every reader to close before the sidecars are truncated" contract of section 5.3
  is the protocol.
- **`TerminalRelaying`** (the CLI as the collect connection sees it: one note, one prompt)
  and **`KeychainDiagnosing`** (`doctor`'s reachability line and S1(d2)'s round trip, which
  answer `OSStatus` detail no other seam has) are the other two.

The seams are one value, `AgentEnvironment`, and `DomainManager` is constructed with it
rather than reading singletons. That is what lets a scenario run two agents in one process.
`DomainManager.shared` still exists for the XPC command layer, which is reached from an
object made per connection and has nothing else to hold; a scenario binds its own through
`AgentCommandContext`, a task local, for the duration of one call.

## 3. (b) `SystemModel`: a simulated fileproviderd, Finder and launchd

`SystemModel` is a package library target. It drives `ProviderCore` and `AgentRuntime` through
the protocols above and behaves the way macOS was *measured* to behave, with the version's
quirk table deciding every difference.

### 3.1 Shape

```swift
let sys = SystemModel(macOS: .v26_4, server: ServerModel(profile: .debianOpenSSH))
let domain = try await sys.addLocation(nickname: "nas", remotePath: "/home/alec")
try await sys.finder.open(domain.mount / "Documents")     // one enumerateItems, ever
try await sys.server.write("Documents/note.txt", "hello") // a change on the server
try await sys.advance(.seconds(60))                        // the detector's cadence
#expect(sys.finder.listing(domain.mount / "Documents").contains("note.txt"))
```

`sys.advance` moves the driven clock, releases whatever the simulated schedulers owe, and
returns when everything queued has run. There is no real sleeping anywhere in the suite.

Three parts:

- **`SystemModel.FileProviderD`** — the replica (a tree of items with `isDownloaded`, size,
  versions, xattrs, `tagData`, content policy, pending state), the domain list, the working-set
  change stream, the sync-anchor bookkeeping, the pending-operation queue with its retry
  schedules, the error throttler, the download scheduler with its concurrency ceiling, and the
  trash node. It calls `ProviderCore` exactly as fileproviderd calls the extension, including
  **launching a fresh provider instance for every working-set signal**.
- **`SystemModel.Finder`** — the user: `open(folder)`, `cat(file)`, `write(file)`,
  `save(file)` (the atomic-save shape), `rename`, `delete`, `chmod`, `tag`, `duplicate`,
  `contextMenu(for:)` (which evaluates the activation rules the way `fileproviderctl evaluate`
  does), and a `walk` that is answered from the replica and never reaches the extension.
- **`SystemModel.Launchd`** — the agent job, `RunAtLoad`, `KeepAlive`/`SuccessfulExit`, SIGTERM,
  the login-item record, `unregister`'s asynchrony and the launch-constraint window, and bundle
  replacement.

### 3.2 The quirk table

```swift
public struct Quirk {
    public let id: QuirkID              // "MQ-005"
    public let statement: String
    public let measurements: [Measurement]   // one per (version, date, results.md entry)
}
public struct Measurement {
    public let versions: [MacOSVersion]
    public let value: QuirkValue         // .bool, .int, .duration, .schedule, .errorCode, .enum
    public let source: SourceRef         // results.md date + heading, DESIGN.md §, gotcha no.
}
```

`QuirkTable(for: .v26_4)` resolves each id to the value measured nearest that version, and
**refuses to resolve an id with no measurement covering it**: a scenario that depends on an
unmeasured quirk on a version we claim to support fails loudly with the id and the runbook step
that would measure it. That is the mechanism that turns "we never checked on 14" from a silent
assumption into a build failure.

Adding macOS 27 is: run the runbook, write the results.md entry, add
`.init(versions: [.v27_0], value: …, source: …)` to each quirk whose value moved, add `.v27_0`
to the CI matrix. **No scenario changes.**

### 3.3 The rules the model implements

Each rule is a `SystemModel` behaviour keyed to a quirk id (the ids are catalogued in
`docs/quirks/macos.md`); a version whose table says otherwise gets the other behaviour.

**Enumeration and the working set**

- A folder is enumerated **once, ever** (`MQ-001`). Revisiting it, and a remote change landing
  while it is open, produce no container-enumerator call at all. `SystemModel.Finder.open`
  therefore calls `enumerateItems` only the first time; every later view is served from the
  replica.
- The working set is only a change stream: `enumerateItems` on it returns nothing (`MQ-002`).
- The system launches a **fresh provider instance** for every working-set signal (`MQ-003`), so
  the model tears down and rebuilds the `ProviderCore` instance on each signal, which is what
  makes the `indexReady` race real rather than theoretical.
- An **empty change set at the anchor the system already holds** is read as "up to date" and the
  change is dropped until something else signals (`MQ-004`).
- A change enumeration that keeps failing is **throttled** (`MQ-005`) on the measured schedule:
  the domain's fetch-event stream went to a **47-minute** retry after **27** consecutive errors
  (2026-09-08, macOS 26.6.2, the 0.1.2 field failure). The model counts errors per domain,
  applies the schedule and **stops delivering server-side changes** while throttled — which is
  precisely the symptom that shipped, and `A2` asserts a healthy domain never reaches the
  throttle.
- `syncAnchorExpired` makes the system re-ask from a fresh anchor (`MQ-006`).
- The system does **not** time out an `enumerateItems` held the full 60 s (`MQ-007`).

**Versions, writes and conflicts**

- The system **believes whatever version a `modifyItem` reply carries**; it never re-fetches and
  never re-offers (`MQ-013`). The replica therefore ends up holding local bytes under a remote
  version unless the provider evicts, which is what `D1`/`D2` assert.
- A queued write is **retried for ever on a doubling backoff** — 5.5, 10.6, 20.3, 43.0, 79.4,
  153.2, 331.3 s and still climbing ten minutes in, with no ceiling seen (`MQ-035`) — and each
  retry arrives **on a freshly launched instance**.
- A **failed `fetchContents` is never re-issued** (`MQ-036`). There is no interval to model.
- `signalErrorResolved(.serverUnreachable)` flushes the queue in ~20 ms; `signalEnumerator`
  alone does not, and neither does reconnecting (`MQ-037`).
- `.filenameCollision` from `createItem` is **retried for ever with no alert**, on the measured
  0 s / 0.04 s / 5 s / 15 s … backoff, and the pending-items enumerator stays empty (`MQ-014`).
- A real collision inside Finder never reaches the provider (`MQ-015`); a case collision arriving
  from the server is renamed by the system **on its replica only**, silently (`MQ-016`).

**Eviction and content policy**

- `evictItem` **evicts a directory recursively** and works on the root container (`MQ-020`).
- An eviction issued straight after a `modifyItem` reply is refused `-2008`
  `NSFileProviderErrorNonEvictable` (`MQ-017`); an item with a pending upload is refused the same
  code, and so is a kept item, so **the code says nothing about why** (`MQ-018`).
- Evicting the *parent directory* of a pending item fails differently and opaquely:
  `NSCocoaErrorDomain` 4101 with an underlying `contentVersionMismatch` (`MQ-019`).
- `.inherited` is the neutral policy (`MQ-026`); an eager policy pulls a whole subtree including
  never-enumerated subfolders (`MQ-028`) and works on the root container (`MQ-030`); an explicit
  `.downloadLazily` on a child beats an eager ancestor (`MQ-027`).
- The **eager `contentPolicy`, not `allowsEvicting`**, is what refuses an eviction (`MQ-024`);
  the system puts `allowsEvicting` back and drives the menu from `isDownloaded` (`MQ-025`).
- Ancestors reported through the working set are **not ingested**; `getUserVisibleURL` plus one
  `lstat` of the replica is what starts it (`MQ-029`).
- With a pin in place, or within 5-10 s of an unpin, an `evictItem` on the root container fails
  as a whole (`MQ-033`, `MQ-034`).
- The system holds **six** `fetchContents` open at once for an eager subtree (`MQ-031`), and
  eight concurrent opens from a shell arrive as **eight simultaneous foreground calls**
  (`MQ-032`) — the ceiling is a size, not a cap.

**Trash**

- `NSFileProviderDomain.supportsSyncingTrash` **defaults to YES** (`MQ-008`); the system creates
  the trash node itself at `add(domain)` time (`MQ-075`).
- Answering `enumerator(for: .trashContainer)` with `.noSuchItem` makes the system delete the
  trash from disk, fail, re-materialize it and ask again, about once a second, for ever
  (`MQ-009`) — the `.Trash` hang.
- Answering `NSCocoaErrorDomain`/`NSFeatureUnsupportedError` makes it **throttle, give up after
  two attempts and remove `.Trash` from the mount** (`MQ-010`).

**Attributes, names and identity**

- Finder tags arrive as `tagData` with `changedFields = 0x10` and an **empty** xattr dictionary
  (`MQ-042`), and are **wiped on the next re-download** unless the item returns them (`MQ-043`).
- The system decides which xattrs the extension is told about at all — only names carrying
  `XATTR_FLAG_SYNCABLE` (`MQ-044`) — and preserves xattrs across an eviction (`MQ-045`).
- A `.DS_Store` written into the mount **never reaches the extension** (`MQ-046`).
- `chmod` arrives as `.fileSystemFlags` (`0x100`); a `chmod +x` on an already-755 file produces
  no call at all (`MQ-047`). A Finder rename is one `modifyItem`, `changedFields = 0x2`
  (`MQ-048`). An atomic save keeps the identifier (`MQ-049`).
- `displayName` is the **bare nickname**: the mount directory is `SSHDrive-<name>` and the
  sidebar reads `SSH Drive - <name>` (`MQ-050`). `add(domain)` with the same identifier and a new
  `displayName` **renames in place** (`MQ-051`) and may report `NSCocoaErrorDomain` 4099 *after*
  the call has landed (`MQ-052`).

**Menus, badges and drawing** (modelled as *rule evaluation*, never as pixels)

- The activation rule binds `fileproviderItems`, lower-case p, as a **key path**; either mistake
  drops the entry silently (`MQ-055`). `SystemModel.Finder.contextMenu` evaluates the rule the way
  `fileproviderctl evaluate` does, so both mistakes are caught on Linux.
- Finder's own entries are `Download Now` / `Remove Download` by `isDownloaded` and nothing else
  (`MQ-053`); ours are top level, last, one of a pair, present on the window background and
  **absent from the sidebar row** (`MQ-054`); `Move to Bin` is offered with no `allowsTrashing`
  (`MQ-058`); there is no cancel control on a download (`MQ-059`); a decoration's Info.plist keys
  are the bare four and `BadgeImageType` is a badge UTI (`MQ-056`). The last four are asserted
  against the *declaration* (Info.plist and served capabilities), not against drawing.

**Offline and the agent's absence**

- Requests keep reaching the extension while the domain is connected and every call fails fast
  (`MQ-038`); a `readdir`/`lstat` walk is served from the replica and reaches us not at all
  (`MQ-039`).
- `disconnect(reason:)` from inside the extension works, putting the domain in state 4; the
  replica listing and queued writes survive, and re-launching the app lifts it (`MQ-040`,
  `MQ-041`, `MQ-074`).
- From `fetchContents`, `.noSuchItem` and `.cannotSynchronize` both leave the item in place and
  differ only in what the reader is told (`MQ-012`); from `item(for:)`, `.noSuchItem` deletes the
  user's file (`MQ-011`).

**launchd, login item, packaging** (the ones that *are* modellable as state machines)

- `SMAppService.register()` does not repair a registration whose bundle was replaced (`MQ-062`);
  `unregister()` returns before launchd has dropped the job, and a `register()` inside that
  window leaves the job carrying the previous bundle's launch constraint and spawning-and-dying
  on a 10 s throttle for ever (`MQ-063`).
- LaunchServices registers no plugin of a quarantined bundle nobody has launched, so the appex
  does not exist and `fileproviderd` answers `FP -2001 / -2014` (`MQ-061`).
- `launchctl setenv` does not reach a launchd agent (`MQ-067`).
- Death by signal is an unsuccessful exit and `KeepAlive` restarts at once, from whatever bundle
  is at the path (part of `P4`).

**atime**

- atime follows the `relatime` rule (`MQ-023`), an eviction moves it (`MQ-021`), and **something
  in the system advances a materialized file's atime minutes after the fetch** with no read of
  ours near it (`MQ-022`). The model advances atime on the deferred schedule, which is what makes
  `G1` — a file fetched 280 s ago under a 60 s TTL with a 23 s atime — reproducible without a Mac.

**Symlinks and the local blob** (added 2026-09-08, from S8 and S10, which had measurements and
no catalogue rows)

- The system makes a **real symlink** under CloudStorage for an item served as one, and
  `readlink` answers the row's target (`MQ-076`); a **dangling** one is indistinguishable from a
  live one, size and all (`MQ-077`).
- A create the agent refuses surfaces **only** as the item's `uploadingError` (`MQ-078`): `ln -s`
  exits 0 and the item stays in the mount, so `sshdrive status` is the one route to the user.
- A tag change is asked **once even when the reply freezes the metadata version** (`MQ-079`), so
  the xattr hash is not what ends the exchange; what it is for is an *agent-side* change of the
  stored blob.
- A pending edit on an item we report deleted comes back as a **`createItem`** of the same name
  and then collides for ever (`MQ-080`), which is why §6.4's guard holds pending items.

**Where the model is uncertain, it says so.** Four rules read a measurement that was taken once
or bracketed rather than measured, and each carries a `confidence:` note in the rule and in the
catalogue row: the window in which an eviction straight after a `modifyItem` reply is refused
(`MQ-017`, modelled as exactly the first call); the single deferred atime advance (`MQ-022`,
one file, one reading); the 5-10 s unpin settle window and the minute the root was still refused
in (`MQ-034`, `MQ-034.root`, taken at their upper bounds); the length of the window
`unregister()` leaves open (`MQ-063`, bracketed at five seconds by a command that worked); and
that the dividing line in `MQ-029` is a **new container** rather than a new item, which is the
model's reading of an outcome measured three times rather than a measurement of its own.

## 4. (c) `ServerModel`: the remote half

`ServerModel` is the second package library target: a whole SSH/SFTP server universe in
process, plus the parts that are honest to run for real on Linux.

### 4.1 `ServerProfile`

One value describes a server, and the testbed's twelve services are twelve constants.

**As built (2026-09-08, §8 step 6)** the sketch below is right in shape and differs in
three names: `FindFlavour` is `ServerFindFlavour` (so a test may import `AgentCore` and
`ServerModel` together without qualifying either), `clockOffset` is a `TimeInterval`, and
every constant carries a `quirks: [ServerQuirkID]` list naming the rows it is a carrier of.
The account variants of one service - `deb/pw`, `deb/keypass`, `deb-shells/bashbg`,
`deb-shells/forcesftp`, `deb-extsftp/extquiet` - are constants of their own, and so are the
owner's `ownerDebian` and `ownerTailscale`.

```swift
public struct ServerProfile {
    var sftp: SFTPImplementation      // .opensshExternal | .opensshInternal | .goPkgSFTP
    var extensions: [String]          // the advertised SSH_FXP_VERSION list, in order
    var findFlavour: FindFlavour      // .gnu | .busybox | .busyboxNoCmin | .bsd
    var loginShell: LoginShell        // .bashQuiet .bashNoisy .bashBackgroundHolder
                                      // .zsh .fish .tcsh .dash .busyboxAsh .none
    var forceCommand: ForceCommand?   // .internalSFTP
    var maxSessions: Int              // 10, or 2 for deb-maxsess
    var sessionGrouping: SessionGrouping   // .ownProcessGroup | .sharedWith("tailscaled")
    var clientAliveInterval: Int?
    var reapsOrphans: Bool            // false everywhere measured
    var clockOffset: Duration         // the one thing a container could never give us
    var umask: mode_t
    var caseInsensitive: Bool
    var renameOverwrites: Bool
    var hasSHA256Sum: Bool
    var hasMkfifo: Bool
    var unameSM: String               // "Linux aarch64", "FreeBSD amd64", …
    var identificationString: String  // "OpenSSH_9.2p1 Debian-2+deb12u10", "Tailscale"
    var auth: AuthShape               // .key | .password | .keyboardInteractive | .none
}

extension ServerProfile {
    static let debian            // deb 2201: OpenSSH 9.2, GNU find, ClientAliveInterval 15/3
    static let debianShells      // deb-shells 2202: every shell shape + ForceCommand
    static let debianExternalSFTP// deb-extsftp 2203: external sftp-server behind noisy rc
    static let debianKbdInt      // deb-kbdint 2204
    static let debianMaxSessions // deb-maxsess 2205: MaxSessions 2
    static let alpine            // alp 2206: busybox find, internal-sftp, musl
    static let alpineExternalSFTP// alp-ext 2207
    static let tailscaleSSH      // ts-ssh: none auth, Go pkg/sftp, shared process group
    static let freeBSD           // not in the testbed at all; the model is the only coverage
    static let synologyDSM       // busybox without -cmin, small max_user_watches
}
```

The extension sets are exact, because `status` reads them: Go `pkg/sftp` advertises **exactly**
`hardlink@openssh.com`, `posix-rename@openssh.com` and `statvfs@openssh.com` and nothing else
(`SQ-024`); OpenSSH's own server adds `fsync`, `lsetstat`, `limits`, `expand-path`, `copy-data`,
`home-directory`, `users-groups-by-id` (`SQ-025`); Alpine's `internal-sftp` offers the same set
as the external server (`SQ-026`).

### 4.2 The fake transport and the fake exec channel

The real `ssh` binary cannot be run on this box without a server, so two seams stand in, and
both speak **the same `SSHProcess.ByteStream`** a mux client's stdio does — which is the whole
point: `SFTPClient`, `RemoteScript`, `SweepPlan`'s script, `Sentinel`, the heartbeat wrapper and
the helper's NDJSON reader all run **unmodified**.

- **`ServerModel.FakeSFTPServer`** — a real SFTP v3 **wire** server over a `ByteStream` pair. It
  speaks the protocol, not a mock of it: `SSH_FXP_VERSION` with the profile's extension list,
  status *classes* and no errno so `ENOSPC`/`EEXIST`/`ENOTEMPTY`/`EXDEV` all arrive as a bare
  `FAILURE` (`SQ-028`), OpenSSH's reversed `SSH2_FXP_SYMLINK` argument order (`SQ-029`),
  `opendir` that **follows a symlink** (`SQ-030`), `readdir` that carries attributes but no link
  target (`SQ-031`), `limits@openssh.com` values, `posix-rename` present or absent, a plain
  `rename` that does or does not overwrite (`SQ-034`), `ETXTBSY` on a write over a running
  executable (`SQ-032`), `mkdir` attributes filtered by the umask (`SQ-033`), and case folding.
  The existing `SFTP.FakeTransport` stays as the fast in-memory double for tests that do not care
  about the wire; `FakeSFTPServer` is what the transport-level scenarios use.
- **`ServerModel.FakeExecChannel`** — an exec channel whose remote end is **a real POSIX shell on
  this Linux box**. `/bin/dash` is Ubuntu's `/bin/sh`, `bash` is present, and `busybox ash` is
  one package away; the channel picks the profile's shell, prepends the profile's rc-file noise,
  applies the `ForceCommand` refusal sentence where the profile has one, enforces `MaxSessions`,
  and models the session's process-group policy with a real `setsid`/shared-pgid so
  `kill -TERM 0` really does or does not reach a bystander. A scenario that needs a shell the box
  does not have (`fish`, `tcsh`, `zsh`) skips with a named reason rather than pretending.

  **The box is a seam too** (2026-09-08). `ServerModel.HostTools` measures what the machine
  running the suite can actually do, once per process, and a scenario that meets one of those
  bounds skips with the sentence it returns - an `XCTSkip` naming the platform fact, never a
  silent `#if`. Three bounds bite today. The local `find` is probed by **what it accepts**
  rather than by what it prints (`SQ-081`, the same rule `SQ-002` states for a server), so a
  sweep row that only needs *a* `-cmin` runs against GNU findutils on Linux and real BSD
  `find` on a Mac instead of being pinned to a flavour, and only a busybox profile is ever
  shimmed. The filesystem is asked whether it will hold a name that is not valid UTF-8
  (`SQ-080`): APFS will not, so `H7`'s real-`find` half is Linux-only while its
  `partitionRoots` and SFTP-wire halves run everywhere. And `PATH_MAX` and
  `sockaddr_un.sun_path` are read from the box rather than written out (`SQ-085`) - a harness
  tree deep enough to outrun a channel's 4 MB buffer is over the Darwin limit at Linux's
  dimensions, and every `open` then fails silently.

  `FakeSSH` also tells `ControlSocket` what the kernel will *call* a running stub. The stub is
  a shell script named `ssh`; Linux takes a process's short name from the script, XNU from the
  interpreter binary, and macOS launch constraints `SIGKILL` a copy of any system shell, so
  there is no binary named `ssh` to point a shebang at (`SQ-082`).
  `ControlSocket.masterProcessName` is the seam - the same shape as
  `SSHProcess.sshBinaryPath` - and `install()` sets it to a **measured** name, read from a
  probe script that prints before it sleeps, because macOS's `/bin/sh` is a launcher that
  re-execs `bash` and a name sampled on a timer is `sh` or `bash` depending on how cold the
  box is. Without it, `K4`'s liveness and both of `K6`'s pid-based routes could not run on the
  one platform whose branch of `ControlSocket` they are about.

  One artifact the harness suppresses rather than asserts around: a shell prints
  `Killed`/`Terminated` on its own stderr when a foreground child dies by a signal, and dash
  writes it to the *command's* redirected stderr rather than its own (`SQ-084`) - while
  `SQ-011` is the claim that a signal-killed remote command says nothing at all.
  `FakeSSH.run_session` hands the session its real stderr on fd 4 and points its own at
  `/dev/null`, which lets `J13` pick its signal for what it proves: `SIGKILL`, since a test
  child inherits an ignored `SIGINT` on Darwin and an ignored `SIGPIPE` everywhere
  (`SQ-086`).

  **A scenario that sweeps or kills by prefix takes the directory it acts on.**
  `ControlSocket.sweepOrphans(in:)`, `liveMasterPIDs(in:)` and `killStrayMasters(in:)` all
  default to the real `$TMPDIR` - the shipping blast radius `agent stop` needs - and a test
  passes one of its own, because `swift test` runs the swift-testing suites **concurrently
  with** XCTest in a single process. `K6` killing by the `ControlPath=$TMPDIR/sshdrive-`
  needle was reaching suite `Q`'s live masters and failing two or three of its nine, a
  different two or three every run.

  The same rule holds for anything else a scenario installs process-wide. Suite `Q` is
  `.serialized` because `SSHProcess.sshBinaryPath` decides which stub *every* `ssh` in the
  process is, and its bed stops its agent **before** putting that path back: a `DomainManager`
  handed to a detached `Task` outlived its own bed, went on reconnecting on the breaker's
  schedule, and dialled the next scenario's stub.

  This is the deliberate design choice of the whole document: **the shell scripts are tested
  against real shells, because that is where three of our worst bugs lived** — the `;;` syntax
  error dash rejected, the `{ … }` group the heartbeat reader would otherwise eat, and the
  `printf "\0<sentinel>"` that ate its own sentinel.

- **`ServerModel.FakeSSH`** — a small executable the package builds, installed as the
  `TransportLauncher`'s "ssh". It exists so `SSHInvocation`'s argv assembly, `Spawn.swift`,
  `ExitClassification` and `ControlSocket` are exercised for real: it binds a real
  `ControlPath` socket, answers `-O check` with `Master running (pid=NNNN)` and `-O exit`,
  honours (or ignores) `ControlPersist`, prints `Permission denied (publickey,password)` /
  `Could not resolve hostname …` / `ControlSocket already exists, disabling multiplexing`
  on stderr **with CRLF line endings** (`SQ-035`), prints `remote software version …` only at
  `DEBUG1` and above (`SQ-036`), invokes `SSH_ASKPASS` with the measured prompt strings including
  their trailing spaces, applies OpenSSH's readconf **first-setting-wins** rule so writing
  `ProxyJump=none` before `ProxyCommand` really does discard the `ProxyCommand` (`SQ-038`),
  percent-expands a `ProxyCommand` before handing it to `/bin/sh` (`SQ-039`), and exits 255 with
  nothing on stderr when its remote command was killed by a signal (`SQ-011`).

  A faster pure in-process `TransportLauncher` is available for scenarios that do not care about
  argv, but the argv-shaped scenarios (`K1`–`K6`) use the binary.

### 4.3 What `ServerModel` encodes

Every server-side quirk in `docs/quirks/servers.md`: no busybox has `-cmin` and busybox `find
--version` prints an error and **exits 0** (`SQ-001`, `SQ-002`); `-printf` likewise absent
(`SQ-003`) and a busybox `-cmin` fails the whole sweep rather than losing a field (`SQ-004`);
`-mmin` misses a ctime-only change (`SQ-005`); the time test and `-printf` each cost a `stat`
per entry (`SQ-006`); `find` has no portable `--` (`SQ-007`); a bare background process survives
an abrupt client kill on every server measured, with `ClientAliveInterval` set or not (`SQ-008`,
`SQ-009`); **Tailscale SSH puts every session in `tailscaled`'s process group**, so a
`kill -TERM 0` from one session kills the others *and the connections under them* (`SQ-010`);
sshd gives an OpenSSH session a group of its own (`SQ-012`); a `ForceCommand internal-sftp`
account may answer an exec channel with the plain sentence `This service allows sftp connections
only.` (`SQ-013`); an external `sftp-server` behind a noisy rc file puts text in front of the
`VERSION` reply (`SQ-014`); rc files print on non-interactive startup and `bashbg` leaves a child
holding stdout so EOF never arrives (`SQ-015`, `SQ-016`); Debian's `sh` is dash, which has no
`read -t` and answers `;;` with a syntax error (`SQ-017`, `SQ-018`); `MaxSessions 2` leaves one
spare channel and a channel is proved open only by completing the SFTP handshake on it
(`SQ-021`, `SQ-022`).

## 5. (d) The scenario suite

**107 scenarios in 14 suites**, one per past failure recorded in `docs/spikes/results.md` or
DESIGN.md §13. Ids are stable for ever; a scenario is never renumbered, only retired with a
reason. They live in `Tests/ScenarioTests/`, one file per suite, and each is parameterised over
the macOS versions in the matrix.

The `Harness` column: **S** = SystemModel, **V** = ServerModel, **SV** = both, **U** = pure unit
(no simulator needed), **VM** = the assertion is a VM runbook step and the scenario asserts only
the part that is modellable (see §7).

### Suite A — the working set, anchors and enumeration

**Implemented 2026-09-08** in `Tests/SystemModelTests/WorkingSetScenarios.swift` (eleven
tests: A2 is three, adding the bite-proof against a copy of the 0.1.2 enumerator and the
recovery that makes the `signalErrorResolved` call). They run on Linux against a real index
and the shipping `ProviderCore`.

| Id | Name | Setup | Action | Assertion | H |
|---|---|---|---|---|---|
| A1 | Empty change set at the held anchor | A domain with rows; the reader deliberately not usable | Delete a file on the server, apply it to the index, signal the working set | The provider **never** answers `finishEnumeratingChanges(upTo: theSameAnchor)` with nothing; the deletion reaches the replica within one signal | S |
| A2 | The `.serverUnreachable` storm | A healthy agent; the reader not ready on the first instance of each signal | 40 working-set signals in a row | Fewer than the throttle threshold (27) consecutive failures; `SystemModel.FileProviderD.throttleState` stays `.none`; every change lands. **This is the 0.1.2 regression** | S |
| A3 | Reader-not-ready on a fresh instance | `indexReady` delayed past the first `enumerateChanges` | One working-set signal | The provider asks the agent over `AgentChannel` instead of failing, and the change is delivered from the agent's identical query | S |
| A4 | `currentSyncAnchor` must not invent 0 | The reader not usable, rows past sequence 0 | The system asks for the current anchor | The answer comes from the agent, not `0`; no `syncAnchorExpired` is provoked | S |
| A5 | Anchor expiry reports once and sweeps once | Rows trimmed past the system's anchor | `enumerateChanges` from the stale anchor | `.syncAnchorExpired` answered, `reportAnchorExpired` called exactly once, and exactly one full sweep runs | S |
| A6 | A folder is enumerated once, ever | A listed folder | Revisit it; change it on the server; revisit again | Exactly one `enumerateItems`; no `enumerateChanges` on the container; the change arrives through the working set | S |
| A7 | A new sibling needs a working-set signal | A folder already listed | The agent creates a conflict copy in it | Without the signal Finder never shows it; with it, it appears | S |
| A8 | A 60 s `enumerateItems` is not taken away | Transport hang of 60 s | `enumerateItems` | The call completes at ~60 s, the answer is taken, the provider instance survives | S |
| A9 | The working set enumerates no items | — | `enumerateItems` on the working set | Zero items, `finishEnumerating(upTo: nil)` | S |

### Suite B — trash

**Implemented 2026-09-08** in `Tests/SystemModelTests/TrashAndSymlinkScenarios.swift` (four
tests: `B1` is two, the second driving the 0.1.0 `.noSuchItem` answer through the same model
and asserting the mount hangs).

| Id | Name | Setup | Action | Assertion | H |
|---|---|---|---|---|---|
| B1 | The `.Trash` materialize loop | A fresh domain | The system creates its trash node and asks `enumerator(for: .trashContainer)` | The provider answers `NSFeatureUnsupportedError`, **never** `.noSuchItem`; the model gives up after two attempts and removes `.Trash`; a `stat` of `.Trash` returns | S |
| B2 | `supportsSyncingTrash = false` alone is not enough | Domain added with the flag off | Same | The trash node is still created and still asked about twice; the error code is what retires it | S |
| B3 | A `.Trash` create under the root is refused | — | `createItem(filename: ".Trash", parent: .rootContainer)` | Refused feature-unsupported, and nothing is sent to the server | S |

### Suite C — extension lifecycle and XPC

**C1 and C2 implemented 2026-09-08** in `Tests/SystemModelTests/LifecycleScenarios.swift`
(three tests; `C1` is two, the second running the 0.1.0 invalidation handler and asserting
the domain goes permanently disconnected). `C3`-`C5` are pure-unit rows and `C6` wants
`AgentRuntime`.

| Id | Name | Setup | Action | Assertion | H |
|---|---|---|---|---|---|
| C1 | Disconnect-in-invalidation | A provider instance with a live agent channel | The system kills the idle instance; the channel invalidates | The domain is **not** disconnected; the next instance's `indexReady` calls `reconnect()` unconditionally | S |
| C2 | A reader error is `.serverUnreachable` | The index file made unreadable | `item(for:)` | `.serverUnreachable`, never `.noSuchItem`; the replica keeps the user's file | S |
| C3 | The listener picks the interface by peer | Peers claiming to be `sshdrive`, `sshdrive-askpass`, the appex | Each connects | CLI gets `SSHDriveCLIProtocol`, askpass the one-method interface, everyone else the extension's | U |
| C4 | A stranger is dropped | A peer whose identity fails the requirement | It connects | The listener drops it; the error is "cannot reach the agent", not a partial service | U |
| C5 | An agent error survives the trip | An error with a `LocalizedError` description | It is returned over `AgentChannel` | The description survives in `userInfo`; the CLI prints the sentence, not `error 1` | U |
| C6 | A stalled replica call must not wedge the agent | `ReplicaControlling` made to hang for 3 minutes | Any other agent command | It answers within its own deadline; nothing queues behind the replica call | S |

### Suite D — writes, conflicts, atomicity

**D1, D2, D3, D4, D9 and D12 implemented 2026-09-08** in
`Tests/SystemModelTests/WriteScenarios.swift`, together with `F1`, `F2` and `F4`, which are
about the same queue (eleven tests; `D2` and `D3` are two each, one of them `D2`'s
bite-proof: the single un-retried eviction, which leaves the replica holding the local bytes
under the remote version for ever). `D5`, `D6`, `D7`, `D10` and `D11` are the agent's and the
server's rows; `D8` is not claimed.

**D2, D6 and the two new rows implemented 2026-09-08** in
`Tests/AgentRuntimeTests/WriteScenarios.swift`, beside `G10` (nine tests; `D2` is two - the
retry itself and the schedule behind it - and `D10` is two, one per rename semantics).
`D2` has a row on each side: this one is what the **agent** does with the refusal, the
`SystemModelTests` one is what the system does to the replica if it never retries.

| Id | Name | Setup | Action | Assertion | H |
|---|---|---|---|---|---|
| D1 | A `modifyItem` reply is believed | A materialized file | Reply with a version that is not the one written | No second `modifyItem`, no re-fetch, no conflict flag; the replica records the invented version | S |
| D2 | The conflict copy evicts, retried | A local edit and a remote change between base and now | `modifyItem` | A conflict copy is made, the remote item returned, the first `evictItem` is refused `-2008`, the retry at 0.25 s doubling succeeds, and the working set is signalled | SV |
| D3 | `.filenameCollision` only when the name frees | A create onto a taken name | `createItem` | The provider answers it only where the conflict path is about to rename our file away; a standing refusal is asserted to be retried for ever and is therefore forbidden | S |
| D4 | A pending edit on a deleted item | A pending `modifyItem`; the row forgotten | The system re-offers | It arrives as a **`createItem`**, collides, and is retried for ever — which is why D5 exists | S |
| D5 | The guard holds pending items and their ancestors | 40 files, 30 deleted, a pending edit inside a deleted directory | One listing diff | 30 held, the directory holding the pending edit held **as an ancestor**, a fetch of a held item answers `.cannotSynchronize`, `accept-deletions` applies them | SV |
| D6 | In-flight paths are invisible to change detection | An upload in flight | A detection cycle over the same directory | Our own write is not read back as a remote change | SV |
| D7 | The conflict check reads `generation` | A same-size, same-second remote change | An overwrite | The conflict is detected, because generation came from the row and not from the wire | V |
| D8 | A pending upload survives a bundle replacement | A held upload; the bundle replaced | The system re-offers to the new instance | The conflict check makes the duplicate safe; a conflict copy, not a loss | S |
| D9 | An atomic save keeps the identifier | A materialized file | The temp+rename save shape | One `modifyItem` on the original identifier; no `createItem`, no `deleteItem` | S |
| D10 | The temp+rename upload restores mode and mtime | A create and an overwrite, on the wire | Upload each | `.sshdrive-upload-<mac8>-<uuid>` then the non-overwriting `rename` (create) or `posix-rename` (overwrite), then the `setstat` putting the mode back through the server's umask (`SQ-033`), then the post-upload `lstat`; both rename semantics are met (`SQ-034`). Added 2026-09-08 | SV |
| D11 | The stale temp sweep takes only our prefix | Our own stale temps, a bystander's similarly shaped names, and one temp whose upload is in flight | A listing | Only ours are swept; the in-flight one is left; a prefix-blind sweep is asserted to take the bystanders. Added 2026-09-08 | SV |
| D12 | Both `fetchContents` failures are reversible | Two materialized items, one answered `.cannotSynchronize` and one `.noSuchItem` | Read each, then `item(for:)` the second | Neither fetch answer removes anything (`MQ-012`); the same code from `item(for:)` deletes the user's file (`MQ-011`). Added 2026-09-08 | S |

### Suite E — the index

| Id | Name | Setup | Action | Assertion | H |
|---|---|---|---|---|---|
| E1 | Nested transactions | A listing whose body appends anchors and deletes rows | One listing | No `cannot start a transaction within a transaction`; inner levels are `SAVEPOINT`s; an inner failure caught by its caller undoes only its own writes | U |
| E2 | A listing is one transaction, holds the writes alone, and compiles a constant number of statements | A directory of new, changed, unchanged and deleted entries plus a symlink | Enumerate it twice | One `BEGIN IMMEDIATE`, one commit; every `INSERT INTO items` inside it and no per-entry row read (`WHERE path = ?1`) inside it; an unchanged row is neither rewritten nor anchored, a changed and a new row get one `modified` anchor each and the missing one a `deleted` anchor, last; and a 2,000-entry listing compiles at most twelve statements, with no `SAVEPOINT` and no `last_insert_rowid()` | U |
| E3 | Sorted keys in the attributes blob | A six-key `LocalAttributes` | Encode it 200 times in one process | Byte-identical every time; the metadata version does not move on its own | U |
| E4 | A local-only row survives | A `.DS_Store` local-only row | A listing that does not mention it | The row and the user's bytes survive | U |
| E5 | The reconcile always clears its flag | A corrupt index | Restore into the live database, then a walk that hits its deadline | The restore goes through the backup API (the sidecars and the open reader keep their inode); `meta.reconciling` is cleared even on the deadline path; the walk runs after `add(domain)`, not inside `start()` | S |
| E6 | `held.dir` follows a rename | A held deletion under a directory | Rename the directory | Both `held.path` and `held.dir` are rewritten; the 5- and 30-minute re-checks resolve | U |
| E7 | A ten-thousand-entry first listing | 10,000 entries on the wire (`FakeSFTPServer` + `RealSFTPTransport`): files with varied sizes, mtimes and modes, 50 subdirectories, 20 symlinks, dot names and two collisions | Enumerate every page, then `item(for:)` all of them through `IndexReaderStore`, then replay the anchors through the working set | The counts, not the clock: one `opendir`, at most one window of readdir over-issue, one `readlink` per link and no `stat` per entry; a constant number of statement compilations and at most three statement executions per entry inside one `BEGIN IMMEDIATE` with no `SAVEPOINT`; one statement per `item(for:)`; no log line per entry; and one loose wall-clock guard. Added 2026-09-09 | V |

### Suite F — offline, the breaker, reconnection

**F5-F11 implemented 2026-09-08** in `Tests/AgentRuntimeTests/ReconnectScenarios.swift`
(seven tests, all on `VirtualAgentClock`, so the breaker's backoff, the ladder's climb-back
hold and section 4.2's once-a-minute presence rule run at their real numbers and cost no
real time). `F1`, `F2` and `F4` are the system's rows and live in
`Tests/SystemModelTests/WriteScenarios.swift`; `F3` is not claimed.

| Id | Name | Setup | Action | Assertion | H |
|---|---|---|---|---|---|
| F1 | `signalErrorResolved` is the only flush | A queued write, the backoff past five minutes | Reconnect with no signal; then `signalEnumerator`; then `signalErrorResolved` | Nothing, nothing, then the `modifyItem` within 20 ms | S |
| F2 | No system retry for a fetch | A `fetchContents` answered `.serverUnreachable` | Wait | No second call, ever; a second read produces a second call | S |
| F3 | A dead connection is retried once | A silently dead master | One read | It succeeds on the retry through the breaker; a **write** is not retried this way | SV |
| F4 | A queued write is re-offered for ever | A faulted write | Twelve minutes of model time | The doubling schedule is followed and never gives up; each retry lands on a fresh instance | S |
| F5 | A call waits for the attempt in flight | Two reads three seconds apart during a 20 s connect | Both | Both wait for the one attempt and both succeed, bounded by that attempt's own remaining deadline, not 60 s from now | SV |
| F6 | Sleep drops, wake reconnects | Two locations, masters up | will-sleep, then did-wake | Both masters dropped by `-O exit`, no reconnect scheduled, the message acknowledged within the 5 s cap; new masters after wake | SV |
| F7 | The reconnect re-opens the helper stream | Tier 2 running, the master `kill -9`ed | The reconnect | The stream is re-opened by the reconnect path itself, in `ReconnectSequence` order — after `applyConnection`, before the signals — and **not** at the next poll cycle; a location that is idle (10 min cadence) is back at tier 2 in seconds | SV |
| F8 | An outage is not a tier verdict | Tier 2 running; the connection stalls until the helper's 60 s heartbeat lapses and the stream dies with the master still nominally up | The stall, then the link back | The downgrade is transient: held for 2 s, doubling to 60 s, cleared outright the moment a connection comes up. It never becomes the session-long downgrade §6.4 reserves for no shell, no exec channel, an unsupported arch, `noexec` and a hash mismatch after a redeploy | SV |
| F9 | Repeated down/up cycles converge | Four outages in a row with 30 s of link between them | Each recovery | Every round ends at tier 2 within one cycle of the link being stable; the breaker's own backoff stays capped at 60 s and the ladder's at 60 s; neither compounds across rounds | SV |
| F11 | The path gate fails fast and spawns nothing | `NWPathMonitor` reporting no path | A request, then the path back | The call fails fast rather than waiting out `ConnectTimeout`, **no `ssh` is spawned at all** while the path is down, and the path coming back connects without waiting out the breaker's backoff. Added 2026-09-08 | SV |
| F10 | The authentication deadline re-arms once per trigger | A location stopped by section 4.2's 60 s deadline | A request with nobody there, a second inside the minute, then one with the user present, then the screen unlock | The absent reading refuses and the second request does not even read the presence test (once a minute); the present-user request re-arms exactly one attempt; the unlock is the other trigger and needs no presence test; each fires once per stop, and a fresh stop arms both again | S |

### Suite G — eviction and pinning

**G1-G6, G8, G9 and the two new rows implemented 2026-09-08** in
`Tests/SystemModelTests/EvictionAndPinningScenarios.swift` (twelve tests; `G1` and `G14` are
two each - `G1`'s bite-proof puts atime back in the `max` and the file survives its TTL for
ever, and `G14`'s runs both misspellings of the activation-rule binding). `G1`, `G4` and `G5`
also have an agent-side row in `Tests/AgentRuntimeTests`, asserting what the *agent* decides;
these assert what the system does to it. `G7` is a pure-unit row.

| Id | Name | Setup | Action | Assertion | H |
|---|---|---|---|---|---|
| G1 | atime is not in the TTL's `max` | A file fetched 280 s ago, TTL 60 s, atime advanced 23 s ago by the model's indexer | One TTL pass | The file is evicted; the atime is logged beside the age the decision used and changes nothing | S |
| G2 | `evict --all` falls back to a walk | A pin in place; then straight after `--unpin-all` | `evict --all` | The single root call fails in both cases; the walk evicts every unkept file with the doubling backoff; the failure is logged, never interpreted | S |
| G3 | `-2008` says nothing about why | A pending item and a kept item | Evict each | Both refuse `-2008`; the loop must not read a pin from it | S |
| G4 | Policy refuses, not the capability | A file that merely inherits a pin, still serving `allowsEvicting` | Evict it | Refused, because the effective content policy is eager | S |
| G5 | An explicit lazy child wins | `Documents/Reports` excluded inside a pinned `Documents` | Signal and settle | One fetch, the direct sibling; the excluded subtree stays dataless | S |
| G6 | A pin on an unseen path | A path with no rows at all | `pin` | Ancestors listed and anchored, then `getUserVisibleURL` + one `lstat`; the subtree downloads. Reporting through the working set alone is asserted **not** to be enough | S |
| G7 | A pin change rewrites descendants | A pinned subtree with nested markers | Change the pin | Every explicit state beneath is cleared first (invariant 2), every known descendant row is rewritten with an anchor each, and the smallest marker change is the one made (invariant 3) | U |
| G8 | Six fetches, and the seventh | A 30-file eager subtree; then eight concurrent opens | Both | Strict batches of six for the subtree; eight simultaneous foreground calls are all admitted and counted, never refused | S |
| G9 | `evictItem` is recursive | A materialized tree | Evict the root container | Every item goes dataless, directories included | S |
| G10 | The transfer scheduler | A queue of background transfers, then a foreground one; then a cancel | Both | Four run at once, foreground before background, the window split between them, a cancelled transfer stops and frees its slot, and eight simultaneous opens are all admitted and counted (`MQ-032`) - the six-fetch ceiling bounds an eager subtree (`MQ-031`), never the queue. Added 2026-09-08 | S |
| G11 | Pins export and import | A marker set with an exclusion nested under a pin | `pins --export`, then `--import` onto a fresh location and onto itself | The round trip preserves the set exactly, the import applies the **smallest** marker change (invariant 3) and clears explicit states beneath (invariant 2), and importing a matching file is idempotent. Added 2026-09-08 | S |
| G12 | The agent's own `stat` under its mount is not gated | The TTL loop's `lstat` and `getUserVisibleURL` on its own domain | One pass | Allowed with no prompt, no probe, no guard and no fallback (`MQ-060`); a scripted denial degrades to the index's own `last_fetch` rather than branching. TCC itself stays a VM measurement (section 7). Added 2026-09-08 | S |
| G13 | Finder owns Download Now and Remove Download | One file, dataless then materialized then kept | `contextMenu` | Exactly one of the two, by `isDownloaded` and nothing else (`MQ-053`); `Remove Download` is still offered on a kept item, where the eviction fails. Added 2026-09-08 | S |
| G14 | Our actions are one of a pair, top level, never on the sidebar | The shipped `Info.plist` declaration, read from the repository | `contextMenu` on an item, on the window background and on the sidebar row | One of the pair each time (`MQ-054`), at the top level, absent from the sidebar row, and absent on an empty selection; either misspelling of `fileproviderItems` drops the entry silently (`MQ-055`). Added 2026-09-08 | S |

### Suite H — change detection

**H1, H2, H3 and H6 implemented 2026-09-08** in `Tests/ServerModelTests/SweepScenarios.swift`,
against a real shell and a real `find`. The busybox flavour is a generated `find` shim that
behaves the way BusyBox 1.36.1 was measured to, because this box has GNU findutils and no
busybox; the *shell* rows that need the busybox binary skip by name.

**H4, H5 and H7 implemented 2026-09-08** in the same file (seven tests now), and **H8, H9,
H10 and the new H11** in `Tests/AgentRuntimeTests/DetectionScenarios.swift` (six tests, two
of them bite-proofs). `H4` is the case a container could never provide: a `date` shim driven
by `ServerProfile.clockOffset` (`SQ-054`) is the only coverage that row will ever have.

| Id | Name | Setup | Action | Assertion | H |
|---|---|---|---|---|---|
| H1 | busybox `find --version` exits 0 | `.alpine` | The flavour probe | It reads the `busybox` banner and the `-cmin` answer, never the exit status; the server is not called GNU | V |
| H2 | `-cmin`/`-printf` refused on busybox | A probe that wrongly claims them | Build a sweep | `SweepPlan` refuses them a second time on a busybox flavour | U |
| H3 | `-mmin` misses a ctime-only change | A file with an old mtime, then `chmod` | A sweep on each flavour | GNU `-cmin` finds it; busybox `-mmin` does not; `status` carries the note | V |
| H4 | The window is elapsed time | A server whose clock is five minutes behind (`clockOffset`) | Two cycles | `N = ceil((now - localTimeOfStamp)/60) + 1`; neither clock's absolute value enters; the change is found. **This is the case a container could never provide** | V |
| H5 | A truncated sweep stores nothing | A sweep whose closing sentinel never arrives | The next cycle | `serverTime: nil`, nothing stored, the next window still covers what was missed | V |
| H6 | Every root is spelled `./name` | A top-level directory named `-name` | A sweep | It is passed as `./-name`, the prefix is stripped before `RelativePath`, and the sweep is not taken over by an option | V |
| H7 | A non-UTF-8 root goes to tier 0 | A root named `latin1-caf\xff` | A cycle | It is dropped from the `find` argv and listed at tier 0 in the same cycle | V |
| H8 | The rotation and the caps | 5,000 `materialized` roots | One tier-0 cycle | 64 materialized roots plus the root; `rotationPeriod == ceil(5000/64)`; `viewed` capped at 256 with LRU eviction; pin roots exempt | U |
| H9 | A CLI command is a touch | A location watched only from a terminal | `sshdrive status <name>` | The location's `viewed` reason is refreshed and the cadence does not fall to ten minutes | S |
| H11 | The mass-deletion guard's thresholds | Directories at and either side of every threshold, and a root emptied | One listing diff each | The count, the proportion and the small-directory floor each fire and do not fire at their boundaries; the root has no floor; `held` rows carry `reason` and `checks`; the 5- and 30-minute re-checks run on schedule; `accept-deletions` releases them; a held fetch answers `.cannotSynchronize` (`MQ-011`, `MQ-012`). The pending-item half is `D5`. Added 2026-09-08 | S |
| H10 | A cycle that eats its interval | A 56.8 s cycle against a 60 s interval | The next schedule | The interval becomes three times the last cycle, capped at the insurance interval, and `status` says so; a tier-2 cycle that went nowhere paces nothing | U |

### Suite J — remote execution and the helper

**J1-J8 and J12 implemented 2026-09-08** in `Tests/ServerModelTests/ShellScenarios.swift`,
`HeartbeatScenarios.swift` and `SFTPWireScenarios.swift`. J1 is three tests, one of them the
bite-proof: the wrapper as it stood before 2026-09-08, naming `0`, is run for real against a
real shared process group and a real bystander session, and the bystander dies. J9-J11 and
J13 wait for the helper binary (step 9); J11's stale-FIFO half is already covered on the wire.

**J9, J10 and J13 implemented 2026-09-08** in
`Tests/ServerModelTests/HelperShellScenarios.swift` (four tests; `J13` is two, the second
asserting the death is *reported* with its exit status and its stderr rather than swallowed).
`J9` runs the **real Rust helper** where `helper/target` holds one and skips by name naming
`scripts/build-helper.sh` where it does not. **The new J14** is in `ShellScenarios.swift`.

| Id | Name | Setup | Action | Assertion | H |
|---|---|---|---|---|---|
| J1 | The wrapper names `-$$`, never `0` | `.tailscaleSSH` (shared process group) plus two bystander sessions | Run a wrapped command and let it finish | The bystanders and their connections **survive**; on `.debian` the child and its children still die; on both, nothing we started outlives the connection | V |
| J2 | A bare background child survives a kill | Any profile | Start `sleep &` bare, `SIGKILL` the client, wait 180 s | It is still alive — so the wrapper is the only mechanism there is | V |
| J3 | `ClientAliveInterval` does not help | 15/3 set, and unset | Same as J2 | Identical outcome on both | V |
| J4 | The sentinel's NUL is its own `printf` | A sentinel beginning with a digit | Run a script | The full sentinel is found; a single `printf "\0<sentinel>"` is asserted to lose bytes | V |
| J5 | One `{ … }` group ending in `exit` | The heartbeat reader on the same stdin | Run a sweep script | The shell parses the script whole; the reader does not eat its tail; a bare `.` is never emitted | V |
| J6 | The reader's descriptor and the EXIT trap | dash | Start a long child under the wrapper | The wrapper does not kill its own healthy child; the stamp file is `touch`ed; each subshell clears the trap | V |
| J7 | The relay must not make `;;` | dash and busybox ash | The helper's wrapper | No `Syntax error: ";;" unexpected`; the channel lives | V |
| J8 | The helper is fed through a FIFO | A profile with and without `mkfifo` | Start the helper | With: the wrapper relays into a FIFO and stays the only reader of the channel's stdin. Without: `</dev/null` with the roots on argv | V |
| J9 | `--version` digests its own executable | A helper binary corrupted in place, same size | The deployment check | The mismatch is caught by the `--version` path as well as by `sha256sum` | V |
| J10 | Writing over a running helper | A running helper | Re-upload | `ETXTBSY`; the temp-name-and-rename path succeeds | V |
| J11 | A stale relay FIFO | A wrapper `SIGKILL`ed (its EXIT trap does not run) | The next deployment | `.sshdrive-helper-in-*` is swept with no age rule; `helper off` can remove the directory | V |
| J12 | Tier 2 needs a held channel | `.debianMaxSessions` | The ladder | The helper is refused with `ChannelBudget.allowsPersistentExecChannel` false and one sentence in `status`; the sweep and probe still work | V |
| J14 | The login-shell snapshot, per shell | Each `LoginShell` shape the box can run, with its own rc mechanism | Take the snapshot | Every byte of rc noise before the sentinel is discarded (`SQ-015`) and `PATH`/`SSH_AUTH_SOCK` come back; on `bashbg` the background child holds stdout so EOF never arrives (`SQ-016`) - the snapshot is ended by its **closing sentinel**, and an EOF-waiting reader on the same shell is shown still waiting at its deadline. `busybox ash`, `fish` and `tcsh` skip by name. Added 2026-09-08 | V |
| J13 | The exec channel dies 255 with no stderr | A remote command killed by a signal | Read the exit | Classified as the wrapper's death, not as the mux client's error | V |

### Suite K — transport and `ssh`

**K1, K2, K7, K9-K14 implemented 2026-09-08** in
`Tests/ServerModelTests/TransportScenarios.swift`, against the `FakeSSH` stub that `SSHMaster`
spawns exactly as it spawns `/usr/bin/ssh`. K1 and K2 each run the failing order as well as
the shipping one. **K3, K4, K5 and K6 implemented 2026-09-08** in
`Tests/ServerModelTests/MasterScenarios.swift` (eight tests, three of them bite-proofs: a mux
client without the three guards really does open a second unsupervised connection, a
`ControlPersist` master really does fork away and take the pid, the stderr and the exit
signal with it, and the pre-2026-09-04 name-only orphan sweep really does delete the
package's own test databases). K8 is a pure-unit row and is not claimed.

| Id | Name | Setup | Action | Assertion | H |
|---|---|---|---|---|---|
| K1 | `ProxyCommand` before `ProxyJump=none` | A two-hop chain | Build the master's argv | The `ProxyCommand` is written first; reversing the order is asserted to make `ssh` discard it and resolve the inner hostname | V |
| K2 | `%h`/`%p` doubled per level | The same chain | Build it | `%%h:%%p` at hop *n-1*; hop 1 does not dial the destination; `ControlPath=none` on every hop | V |
| K3 | Mux client options | A missing control socket | Open a channel | `-F /dev/null`, `BatchMode=yes`, `ProxyCommand=/usr/bin/false`; the client fails rather than opening a second unsupervised connection; the failure is classified "master lost", never an auth failure | V |
| K4 | The master's shape | — | Spawn it | `-N`, `ControlPersist=no`, `ControlPath=$TMPDIR/sshdrive-<id8>` and never `%C`; the pid, stderr and exit signal are ours | V |
| K5 | The orphan sweep takes only sockets | `$TMPDIR` holding `sshdrive-nested-<uuid>.sqlite-wal` beside a real socket | The sweep | Only the `S_IFSOCK` candidate is considered; the test databases survive; `doctor` reports a clean install as clean | U |
| K6 | `agent stop` takes the masters | Two locations, one restarted so it holds two masters, one socket already unlinked | `agent stop` | Every master gone: by `-O exit`, by the pid from `-O check`, and by the argv match for a master with no socket at all | V |
| K7 | The host-key question has no hint | A fresh `known_hosts` | The prompt | It arrives with `SSH_ASKPASS_PROMPT` **unset**, exactly like a password; it is classified by its text; a stored password is never answered to it | U |
| K8 | A passphrase prompt truncates | A key path over 100 bytes | The prompt | The prompt text alone is not the key; the prefix is mapped onto the same `ssh -G` `identityfile` list | U |
| K9 | stderr says nothing about a key agent | Missing, dead and locked agents | Three connects | All three produce the same bare `Permission denied (publickey)`; only the pre-spawn socket probe distinguishes them | V |
| K10 | The collect connection runs to 300 s | A three-hop chain with a human at the keyboard | `add` | The collect connection is bounded at 300 s and the master `add` brings up afterwards at 60 s | S |
| K11 | CRLF stderr | `ssh -v` output ending every line with CRLF | Parse it | Line endings are normalised on **unicode scalars** before splitting; the captured version is one token, not the whole transcript | U |
| K13 | A dying connection records no budget | The master killed between the metadata channel and the `MaxSessions` probe | The probe | Nothing is written to `capabilities.json`; the connect attempt fails and §6.3's breaker retries. A refusal `ssh` actually prints, on a master that is still running, is still recorded | U |
| K14 | An abrupt loss makes the cached budget suspect | A cached budget of 3, then a master that died | The next connect | The cache is not believed; the probe runs again; a hand-poisoned "MaxSessions 1" is corrected by the first reconnect rather than surviving every restart | SV |
| K12 | The server is identified | `.tailscaleSSH` and `.debian` | `add` | The identification string is taken from the collect connection at `DEBUG1` and the `debug1:` lines stripped before the classifier; the extension fingerprint names Go `pkg/sftp` or OpenSSH; "not OpenSSH" and "not identified" stay different answers | V |

### Suite L — paths, names and attributes

**L3-L6 implemented 2026-09-08** in `Tests/SystemModelTests/AttributeScenarios.swift`,
beside `E3`, which is about the same blob (seven tests; `L4` is three - the round trip, the
bite-proof against an item that returns no `tagData`, and `MQ-079`'s frozen metadata
version). **L1 implemented 2026-09-08** in `Tests/ServerModelTests/SFTPWireScenarios.swift`: the wire
server really does follow the swapped symlink into `/etc`, and the `lstat` that must come
first is what catches it. **L7 and L8 implemented 2026-09-08** in
`Tests/ServerModelTests/NamesAndAttributesScenarios.swift` (three tests). `L2` is pure unit
and is not claimed.

| Id | Name | Setup | Action | Assertion | H |
|---|---|---|---|---|---|
| L1 | `opendir` follows a symlink | A directory swapped for a link to `/etc` | List it | The listing re-`lstat`s its own directory first, refuses to descend, rewrites the row, deletes every row beneath and answers `.noSuchItem`; **zero** rows under the swapped path | V |
| L2 | `RelativePath` refuses escapes | — | `..`, `../x`, `/etc/x`, `.` through `createItem` and through upload | All refused at the chokepoint, with the component-level message | U |
| L3 | `displayName` is the bare nickname | Nicknames `nas` and `SSH Drive - nas2` | Add both | `SSHDrive-nas` and the stuttering `SSHDrive-SSHDrive-nas2`; the label is `SSH Drive - <displayName>` | S |
| L4 | Tags travel as `tagData` | A tagged file | Evict, re-download | The tag arrives as `tagData` with an empty xattr dictionary, the metadata version moves, and the tag survives because the item returns it | S |
| L5 | The system filters xattrs | Three xattrs, one carrying the syncable flag | Write them through the mount | Only the syncable one reaches the extension; all three survive an eviction | S |
| L6 | `.DS_Store` never arrives | — | Write one into the mount | No `createItem`, no row, nothing on the server; the local-only path is exercised by another writer instead | S |
| L7 | A case collision is hidden | `Makefile` and `makefile` on the server | List | The byte-order incumbent wins, the other is `hidden` with a reason, and a create onto the hidden name is a `.filenameCollision` | V |
| L8 | Locked by derivation | `0666` inside a `0555` directory | Read the row | `caps 65`, `fsFlags 2`; the kernel refuses the write from the served flags and nothing is sent | V |

### Suite M — symlinks

**M3 and M4 implemented 2026-09-08** in
`Tests/SystemModelTests/TrashAndSymlinkScenarios.swift`. **M2 implemented 2026-09-08**
(`SFTPWireScenarios`), together with `SQ-029`'s reversed
`SSH2_FXP_SYMLINK` argument order, which no test above the wire can see.

| Id | Name | Setup | Action | Assertion | H |
|---|---|---|---|---|---|
| M1 | The lexical containment check | Links to `note.txt`, `/home/alec/m4/Other`, `/etc/passwd`, under both root spellings | List | Relative in-root shown, absolute in-root rewritten relative, escaping omitted with a reason, and the check holds under the canonical and the user-typed root | U |
| M2 | A `readlink` per link | A listing with links | Enumerate | One `readlink` per link, because SFTP v3's `readdir` carries no target | V |
| M3 | A refused `ln -s` is a sync error | An escaping target created in the mount | `createItem` | The create succeeds locally, the refusal comes back as the item's `uploadingError` (`MQ-078`), and the sentence reaches the user only through `status`; an in-root relative target reaches `createItem` with the target intact | S |
| M4 | A real link, and a dangling one | A link served for a live target and one for a missing target | List the mount | The system makes a real symlink under CloudStorage and `readlink` returns the row's target (`MQ-076`); the dangling one is indistinguishable - same kind, size = the target string's length, no marker (`MQ-077`). Added 2026-09-08 | S |

### Suite N — the capability report and probes

**N6, N7 and N8 added 2026-09-09**, in the same file, for the two lines of `status` that
can reach the wire: the free-space `statvfs` through the reconnecting transport, and the
state word through an `ssh -O check` inside the master's actor.

**N9, N10 and N11 added 2026-09-09**, beside them, for the two ways a report can wait:
about eighteen hops per location onto the writer's actor, which a synchronous listing
transaction holds, and an unbounded section per location. N9 is the load-bearing one - it
watches the *writer's* connection while `status` runs and requires it to see none of the
report's queries - because a parked `readdir` releases the actor and so cannot reproduce in
one process what a 10,000-row transaction does on a Mac.

**N2, N3 and N4 implemented 2026-09-08** (`SFTPWireScenarios`, `TransportScenarios`,
`ShellScenarios`). **N1 and the new N5 implemented 2026-09-08** in
`Tests/AgentRuntimeTests/CapabilityScenarios.swift`, where the report is built by the
shipping `LocationCommands` and read back out of `sshdrive status`' own JSON. N1's harness
is therefore SV rather than the U the row was drafted as.

| Id | Name | Setup | Action | Assertion | H |
|---|---|---|---|---|---|
| N1 | Never blame a server for our state | A helper still deploying | `add` | The report says `deploying` with no `upgrade:` line; "the server cannot run the remote helper" is reachable only from a real refusal | U |
| N2 | A cached probe keeps its extensions | A cached probe with no live connection | Build the report | The recorded extension set is used, never an empty default; four lines do not silently degrade | U |
| N3 | The `MaxSessions` probe | `.debianMaxSessions` | Probe | It asks "may I hold three at once", proves each by completing the SFTP handshake, drops the bulk channel at 2 and keeps the exec channel | V |
| N4 | A shell-less account | `.debianShells` `forcesftp` | Probe | "no shell access (ForceCommand)", never "shell output unusable", whether the account answers with SFTP framing or with a plain sentence | V |
| N5 | The report names the server, and `fsync`/`limits` are server facts | `.tailscaleSSH`, then `.debian`/`.ownerDebian`, then a server we could not identify | `status` | Tailscale is named from the collect connection's `DEBUG1` string (`SQ-036`) and the missing `fsync`/`limits` are stated as facts **about that server** with no `upgrade:` line (`SQ-024`); OpenSSH has both (`SQ-025`); an *unidentified* server keeps the upgrade line, because it may well be an old OpenSSH. Added 2026-09-08 | SV |
| N6 | `status` never touches the wire | A location connected, then with a connect attempt parked on the virtual clock, then with the breaker open | `status` | No `statvfs`, no `ssh -O check`, no connect attempt and no wait: the free-space figure comes from `capabilities.json` and the state word from the gate. Added 2026-09-09 | SV |
| N7 | Free space is taken at probe time and kept | A connected location, then a `capabilities.json` written before the field existed | `status`, `status --probe` | The figure is captured by `applyConnection`, printed by `status` from the cache, printed with its age once older than an hour, refreshed by `--probe`, and `unknown` where no probe has ever run; an old file still decodes. Added 2026-09-09 | SV |
| N8 | The state word comes from the gate | Connected, backing off, and stopped on a refused password | `status` | `online` / `offline (backing off …)` / `offline (stopped: authenticationFailed)`, with nothing spawned. Added 2026-09-09 | SV |
| N9 | `status` reads the index through its own reader | A tree with a pin, 30 held deletions and an escaping link, and a listing parked in its `readdir` | `status` | The row is complete and correct - the same hidden names the writer would list, 30 held, the pin tree with its counts, the cache totals, the root set - the clock never moves, no third materialized enumerator is drained, and **not one of the queries appears on the writer's connection** (`SQLiteConnection.statementObserver`). Added 2026-09-09 | SV |
| N10 | A stuck location costs its own row, not the report | Two locations, one with its materialized enumerator parked on the virtual clock | `status` with no name | Both rows print, in the order `config.json` holds them; the parked one carries `did not answer within 20 s` and the healthy one is reported in full. Added 2026-09-09 | SV |
| N11 | A rebuild in progress, and an index that is not there yet | `meta.reconciling` set on a live location, then a `StatusIndexReader` on a path with no file | `status`, then the reader directly | The row says the index is being rebuilt, prints the rest of itself, invents no cache or pin totals, and lifts when the flag clears; a missing file is "no index yet", is not remembered, and the same reader opens it once the writer creates it. Added 2026-09-09 | SV |

### Suite P — packaging and lifecycle

These are the ones whose ground truth is a Mac. Each scenario asserts the **state machine** on
Linux and names the VM runbook step that measures the fact behind it (§7).

**P1, P2, P3, P5 and P8's system halves implemented 2026-09-08** in
`Tests/SystemModelTests/LifecycleScenarios.swift`, against `SystemModel.Launchd`. `P1`, `P2`
and `P8` already had an agent-side row in `Tests/AgentRuntimeTests` asserting what the
*agent* decides against `FakeLoginItem`/`FakeLaunchd`; these are the other half - what
launchd, `SMAppService` and LaunchServices do, which is what makes those decisions
necessary - and both halves are keyed on the same `MQ-061`, `MQ-062` and `MQ-063`. `P3` is
two tests, because `MQ-061` holds a **different value in each column**: the quarantined
install was refused on 26.6 and had passed on 26.4, and the model branches on the table
rather than picking one.

**P4 and P9 implemented 2026-09-08** in `Tests/AgentRuntimeTests/LifecycleScenarios.swift`,
beside the agent-side halves of `P1`, `P2` and `P8` (six tests). `P4`'s `agent stop` half is
the agent-side orchestration only - that every master really goes, by all three of section
6.1's routes, is `K6` against the `FakeSSH` stub.

| Id | Name | Setup | Action | Assertion | H |
|---|---|---|---|---|---|
| P1 | The login item after a replacement | A registered job; the bundle deleted and replaced | `register()` alone, then `unregister()` + launch | `register()` alone does not repair it; only the unregister path does | VM |
| P2 | `unregister` waits for launchd | A job launchd has not yet dropped | Back-to-back unregister/register | The `unregister` role polls until the service is gone; a `register()` inside the window is asserted to leave a job dying on a 10 s throttle for ever | VM |
| P3 | A quarantined bundle registers no plugin | Quarantine xattr present | The postflight | `spctl --assess`, then the xattr strip, then unregister and `open -g`; `doctor`'s `quarantine` check is ordered ahead of "extension registered" | VM |
| P4 | SIGTERM exits 0, and `agent stop` takes every master | The agent running with masters | `kill -TERM` | The same shutdown as `agent stop` runs, every master goes, and the exit status is 0 so `KeepAlive` does not restart the old bundle | S |
| P5 | `add(domain)` 4099 after landing | A replica that reports 4099 *after* the call succeeded | `add(domain)` | The domain list is re-read before the error is believed, and the discrepancy is logged | S |
| P6 | Stranded domains are removed | A domain no `config.json` claims, and a missing `config.json` | First start | Both are removed, with their `~/Library/CloudStorage` directories | S |
| P7 | The profile names the signing certificate | A profile issued for another certificate | `release.sh` | The hashes are compared **before** signing; the mismatch is named, the entitlement dropped loudly, and the build carries on | VM |
| P8 | A nickname renames in place | 4 materialized items, 1 pending upload | `set nickname` | The mount directory is renamed, the materialized set and the pending upload are unchanged, nothing is re-fetched, and the pending write still flushes | S |
| P9 | `add` waits for the first deployment | A location whose helper is being deployed | `add` | The upload sentence is printed first, then the report after a bounded wait; `status` ten seconds later agrees with it | S |

### Suite Q — `add`, askpass and the collect connection

**Added and implemented 2026-09-08**, in `Tests/AgentRuntimeTests/AddFlowScenarios.swift`
(nine tests). The suite the architecture was missing: every earlier row about section 4.2 was
about one decision in isolation, and the failures this project has actually had at `add` time
were about the *flow* - a password filed under the alias instead of the resolved host, a hop
keyed off the prompt text, a half-added location left behind by a refusal.

So each of these drives the shipping `LocationCommands.add` end to end: `ServerModel.FakeSSH`
installed at `SSHProcess.sshBinaryPath` answers `ssh -G`, raises the real prompt strings and
binds a real control socket; a real `sshdrive-askpass`-shaped program with a file mailbox in
place of the XPC connection hands each prompt to the **real** `AskpassBroker`; and the mount
that follows runs `RealSFTPTransport` over `ServerModel.FakeSFTPServer` on a real SFTP v3
wire. Nothing between the CLI's arguments and the server is a stub of ours.

| Id | Name | Setup | Action | Assertion | H |
|---|---|---|---|---|---|
| Q1 | Key auth prompts for nothing | A server that takes the key | `add` | No askpass invocation at all, no secret stored, the location created and mounted | SV |
| Q2 | A password is relayed, stored on the **resolved** host, and asked for once | An alias resolving to another hostname, `HostKeyAlias` set | `add`, then a second location on the same host | The prompt is exactly `<user>@<host>'s password: ` (`SQ-060`); the item is keyed `password:<user>@<hostname>:<port>` off `ssh -G` and **not** off the alias or the prompt text; the second location prompts for nothing | SV |
| Q3 | A `ProxyJump` chain is keyed per hop | One hop, then two, each with a different password | `add` | Each hop gets its own item, from the argv of the asking `ssh` and never from the prompt text (`SQ-063`); the port in the key can only have come from that hop's own `-p` | SV |
| Q4 | Keyboard-interactive shares the plain password key | `.debianKbdInt` | `add` | The prompt is `(<user>@<host>) Password: ` (`SQ-062`) and the answer is stored under the same `password:` key | SV |
| Q5 | The host-key question, answered no then yes | A fresh `known_hosts` | `add` twice | It arrives with `SSH_ASKPASS_PROMPT` **unset** and is classified by its text (`SQ-047`); a stored password is never answered to it; the `no` run leaves **no half-added location** - no `config.json` entry, no domain, no domain directory - and the `yes` run succeeds | SV |
| Q6 | A wrong password stores nothing | A server that refuses it | `add` | The secrets store is empty afterwards and, again, nothing half-added | SV |
| Q7 | A bad remote path rolls back | Authentication succeeds; the root does not exist | `add` | The failure is `NO_SUCH_FILE` from the wire, the location is removed from `config.json`, the domain removed and its directory deleted, and the message names the path | SV |
| Q8 | The askpass token lifecycle and prompt classification | Every prompt shape section 4.2 tabulates | `add` | One token per `ssh`, attached to the asking pid, used, committed and then retired so it cannot be replayed; each shape classifies to its own case, the host-key question with no hint included; a PIN or unrecognised prompt is never relayed and refuses the location | SV |
| Q9 | The two-step collect connection | A server accepting both a key and a password (`SQ-064`) | `add` | The first attempt runs `IdentityAgent=none`, the second consults the key agent, `agentDependent` follows which passed - asserted against the argv `FakeSSH` recorded; and the collect connection is bounded at **300 s** while the master `add` brings up afterwards runs at **60 s** (`K10`'s agent-side half) | SV |

**Counts:** A 9, B 3, C 6, D 12, E 6, F 11, G 14, H 11, J 14, K 14, L 8, M 4, N 5, P 9,
Q 9 =
**135 scenarios**, of which 5 are `VM`-anchored and the other 130 run on Linux with nothing
attached. (F7-F9 and K13-K14 were added by the 2026-09-08 working-set and helper-survival
fixes; F10 by step 8, which is where section 4.2's re-arm first became drivable off a Mac;
**D12, G13, G14 and M4 by the same day's `SystemModel` write, eviction, menu and symlink
work** - `MQ-012`, `MQ-053`, `MQ-054`/`MQ-055` and S8's two symlink answers each had a
measurement and no scenario; and **D10, D11, F11, G10, G11, G12, H11, J14, N5 and the whole
of suite Q by the same day's `AgentRuntime`/`ServerModel` pass**, which is where the `add`
flow, the write protocol on the wire, the transfer scheduler, the pin sidecar, the guard's
thresholds, the login-shell snapshot and `MQ-060`'s no-op first became assertable off a
Mac.)

## 6. (e) Seeding: how a VM measurement becomes a quirk

### 6.1 The catalog

`docs/quirks/README.md` describes the format; `docs/quirks/macos.md` and
`docs/quirks/servers.md` are the inventory. One entry per measured behaviour:

```
| id | statement | measured on | source | scenarios |
```

- **id** — `MQ-###` / `SQ-###`, stable for ever.
- **statement** — one sentence, in the present tense, about what the system does. Never about
  what we do in response; that belongs to the design section.
- **measured on** — every version the behaviour was observed on, with the date. A version we
  support and have not measured is written `14 —`, and that empty cell is the work item.
- **source** — the `results.md` entry (date plus heading), the DESIGN.md section, and the
  CLAUDE.md gotcha number where there is one. **`results.md` is the source of truth**: the
  catalog is an index into it and adds no facts of its own.
- **scenarios** — the scenario ids that would fail if the behaviour changed and we did not
  notice.

The machine-readable mirror is `Sources/SystemModel/Quirks/macos.json` and
`Sources/ServerModel/Quirks/servers.json`, one row per (quirk, version, value, source). A test
in `SystemModelTests` asserts the Markdown and the JSON list the same ids, so the two cannot
drift.

### 6.2 The workflow

1. **Measure on the VM.** A behaviour question is a runbook step in `docs/spikes/`, run on the
   VM against the testbed, exactly as every milestone has done. Nothing else changes here.
2. **Record it in `results.md`,** newest date first, as now — the narrative, the commands, the
   output, and what failed.
3. **Add or extend a quirk.** A new behaviour gets a new id and a row in `docs/quirks/`; a
   behaviour that *changed* on a new OS gets a **new measurement on the existing id**, and the
   old measurement stays. Two measurements that disagree are the point of the table, not a
   problem with it.
4. **Teach the model.** One rule in `SystemModel`/`ServerModel` reads the quirk. If the value is
   new, the rule branches on it; if the value only moved, nothing in the model changes.
5. **Write or extend a scenario** if the measurement exposed a failure. A failure with no
   scenario is not fixed.
6. **Run the whole suite on Linux across every version in the matrix.**

### 6.3 Checklist for adding a macOS version

*Last walked 2026-09-08, when the write, eviction, pinning, trash, attribute, menu, symlink and
launchd rules were added to `SystemModel` and `MQ-076`-`MQ-080` were catalogued; and again the
same day for the agent and server halves - the `add` flow, the write protocol on the wire, the
transfer scheduler, the pin sidecar, the guard's thresholds, the sweep window, the login-shell
snapshot, the helper's self-digest and the masters - which added `SQ-055` and turned `MQ-060`
from a VM-only row into `G12`'s no-op rule.*

- [ ] Walk **every** row of `docs/quirks/servers.md` as well where the VM session touched a
      server: an `SQ` row is measured against a service, not against an OS version, so a new
      testbed image is the same kind of work as a new macOS and wants the same walk.

- [ ] Add the version to `MacOSVersion` and to the CI matrix.
- [ ] Run `docs/spikes/macos-version-sweep.md` on a VM of that version against the testbed.
- [ ] Write the dated `results.md` entry.
- [ ] Walk **every** quirk in `docs/quirks/macos.md` and record a value: confirmed, changed, or
      not measured. Not-measured is a legitimate answer and shows as an empty cell.
- [ ] For each changed value, add a measurement row and let the model branch on it. A row that
      differs between two columns is the point of the table, not a problem with it: `MQ-061` is
      one already — the quarantined install was refused on 26.6 and passed on 26.4 — and `P3`
      asserts both without deciding which is "right".
- [ ] Mark any value taken **once**, or bracketed rather than measured, with a `confidence:`
      note in both the catalogue row and the rule that reads it. Five rules carry one today
      (`MQ-017`, `MQ-022`, `MQ-029`, `MQ-034`, `MQ-063`).
- [ ] Check that every new id is in `docs/quirks/macos.md` **and** in the model:
      `swift test --filter QuirkCatalogueTests` is that guard until `scripts/check-quirks.sh`
      exists.
- [ ] `swift test` on Linux, every version in the matrix, green.
- [ ] Update `README.md`'s supported-versions line and DESIGN.md §2 if the minimum moved.

### 6.4 The rule

**The VM measures; it never proves.** A VM session that ends without a `results.md` entry, a
quirk row and a green Linux suite has not finished. No milestone is "done on the VM" any more;
it is done when the scenarios that encode what the VM saw run on this box.

## 7. (f) What cannot be modelled, honestly

These stay VM runbook items. They are listed so that nobody mistakes a green Linux suite for
proof of them.

**Drawing.** What Finder actually puts on the screen: the contextual menu's entries and their
order, the badge's position (measured as an orange disc with a white pin at the trailing edge of
the Name column, not on the icon), the dataless cloud badge, the static progress ring, the
absence of a cancel control, the sidebar's composed label, the "downloaded from the Internet"
dialog. The model evaluates *activation rules and declarations*; it cannot see pixels.

**Code signing, Gatekeeper, AMFI and notarization.** That a provisioning profile must name the
certificate the bundle is signed with; that an ad-hoc signature carrying
`keychain-access-groups` is killed at exec; that `com.apple.application-identifier` on the agent
makes launchd refuse it; that a stapled but unsigned DMG is rejected on the download path; that
`notarytool store-credentials` cannot be run over ssh. These are facts about Apple's toolchain
and there is nothing to simulate.

**LaunchServices, PlugInKit, `SMAppService` and launchd for real.** The model reproduces the
*state machine* (P1, P2, P3) because that is what our code reasons about; whether LaunchServices
really declines to register a quarantined bundle's plugins, and whether a fresh user really needs
no visit to System Settings, are measurements.

**TCC.** That an agent's `stat` of its own domain's mount is allowed as
`kTCCServiceFileProviderDomain` and draws no prompt.

**The real keychain and real key agents.** The data-protection keychain under an access group,
1Password/Secretive behind `IdentityAgent`, Apple's `UseKeychain`, a FIDO key's user-presence
notice and PIN prompt, and the 60 s deadline firing against a touch.

**The Local Network privacy prompt.**

**Timing, throughput and scale as numbers.** 876 ms for an incremental sweep of a million files;
tier 2's 76-903 ms against tier 1's 60 s; 252 MiB/s on a 64 MiB read; 16.7 s for 5,000 roots
without the rotation. The model reproduces the *shape* (that the rotation bounds the cycle, that
`-cmin` costs a `stat` per entry) and never the milliseconds.

**The system's own schedulers.** That the background-download scheduler takes 8-90 s to start an
eager fetch on an idle headless Mac, and that a headless Mac throttles the working-set fetch at
all. The model runs them instantly; a latency claim needs a Mac somebody is using.

**Delivery of IOKit power messages.** `IORegisterForSystemPower` registers on the VM, but the VM
refuses `pmset sleepnow`, so that macOS actually delivers `kIOMessageSystemWillSleep` is
unproven anywhere.

**Real filesystem semantics.** APFS's `relatime` behaviour, case-insensitive comparison of NFC
against NFD, `XATTR_FLAG_SYNCABLE` at the kernel level, and whatever advances a materialized
file's atime minutes after a fetch. The model encodes the *observation*; it does not reproduce
the mechanism.

**Servers we do not have.** ~~A real BSD `find`~~ - no longer true as of 2026-09-08: macOS's
`/usr/bin/find` **is** BSD, and when the suite runs on the build VM `H4` and `H7` exercise the
`.bsd` flavour against a real one. What is still missing is a BSD *server*: FreeBSD's `sh`,
FreeBSD kqueue and the helper's FreeBSD target
(`aarch64-unknown-freebsd` cannot even be `cargo check`ed); a real Synology DSM box, its `sh` and
its `max_user_watches`; armv7 hardware; and **the owner's own Tailscale server** — a behaviour
that reproduces on the testbed's `ts-ssh` is evidence about Tailscale SSH, not about that
machine.

**Real Finder-driven saves** by Pages, Numbers, Keynote, Microsoft Office and Xcode, none of
which are on the VM.

## 8. (g) Migration plan

Ordered, each step sized for one agent, each ending green.

**Step 1 — the logging facade, then the extension seams and the working-set fileproviderd.**
This is first because it is today's failure, and it starts with the one thing that blocks
everything: `swift build` fails at `Sources/Logging/Log.swift:2: no such module 'os'`, and every
target depends on `Logging`.

  1. **[x] Done 2026-09-08.** `Logging/LogFacade.swift`: `#if canImport(os)` keeps `os.Logger`;
     elsewhere `SSHDriveLogger` with the same `trace`/`debug`/`info`/`log`/`notice`/`warning`/
     `error`/`critical`/`fault` methods and a
     `SSHDriveLogMessage: ExpressibleByStringInterpolation` whose
     `appendInterpolation(_:privacy:)` accepts the same `.public`/`.private`/`.sensitive`/`.auto`
     labels (and their `mask:` forms), writing to stderr. **No call site changes** — all 206 of
     them keep their `privacy: .public`, and `Log`'s subsystem and five categories are untouched,
     so `sshdrive logs`' predicates still match. The line is
     `2026-09-08T14:03:11.482Z notice  org.shirls.sshdrive:agent  message`, UTC and formatter-free
     so it renders identically on both platforms; `SSHDRIVE_LOG_LEVEL` raises the stderr floor.
     Beside it `Logging/LogCapture.swift`: `LogCapture` (`install()`/`uninstall()`/`capturing {}`,
     `entries(subsystem:category:level:)`, `messages(…)`), the in-memory hook `SystemModel` will
     read. It sees **every** level including `.debug` — "debug is not persisted" is a unified-log
     rule and stays Darwin's — and on Darwin it sees nothing from `Log.*`, which is still
     `os.Logger`; a test that must pass on both platforms logs through an `SSHDriveLogger` it
     constructs itself. `Tests/LoggingTests/LogFacadeTests.swift` covers the hook, the privacy
     rendering, the line format and one compiled mirror of every call form in the tree:
     **25 LoggingTests green on Linux and on macOS** (one skipped on Darwin), and the Mac's
     `swift test` is unchanged at 661.
  2. **[x] Done 2026-09-08.** The rest of the walk, module by module in dependency order.
     `swift build` and `swift test` now run to completion on this box: **663 tests, 0
     failures, 41 skipped**, per target LoggingTests 25, XPCProtocolsTests 14, ConfigTests
     25, IndexTests 44, SFTPTests 49, SecretsTests 57, SSHProcessTests 119, AgentCoreTests
     330. The Mac is **667** (the same suite plus the two macOS-only constant assertions
     below and one framework-constant test), green, and the Xcode build of all four targets
     still succeeds. What moved:

     - **`XPCProtocols` split.** The `@objc` protocols and the configured
       `NSXPCInterface`s - `AgentProtocol`, `AskpassProtocol`, `CLIProtocol`,
       `ExtensionProtocol`, `Interfaces` - are a new target **`XPCInterfaces`**, whose file
       bodies are `#if canImport(Darwin)` and which only the four app targets link
       (`project.yml` lists it beside `XPCProtocols` for each). The eleven files under
       `Apps/` that name those types gained one `import XPCInterfaces` and nothing else.
       What stays in `XPCProtocols` is the values: `Identifiers`, `ItemSnapshot`/`ItemPage`,
       `AgentError`, `XPCError`, `AskpassEnvironment`, `LocalAttributes`, `Trash`,
       `CodeRequirement` (a string; the `SecStaticCode` call that applies it is in
       `Apps/Agent`), plus `InterfaceVersion.swift` and `ProcessArguments.swift`, which came
       out of the two files that moved.
     - **`Config` gained `GroupContainerLocating`** (`Sources/Config/GroupContainerLocating.swift`):
       `SystemGroupContainerLocator` is the unchanged
       `containerURL(forSecurityApplicationGroupIdentifier:)` and stays the default on
       Darwin; off Darwin the default is `EnvironmentGroupContainerLocator`, reading
       `SSHDRIVE_GROUP_CONTAINER`, and `FixedGroupContainerLocator` takes a directory
       directly. `GroupContainer.locator` is settable and `resetLocator()` puts it back.
     - **`Index`** got a `CSQLite` system-library target (module map plus a `shim.h`
       including `<sqlite3.h>`), depended on **only on Linux**, so `import SQLite3` is
       still Darwin's on macOS. The Linux box needed `libsqlite3-dev`; `IndexTests` runs
       against real SQLite there.
     - **`Secrets`**: `SecretsError` and `KeychainSecretsStore` are behind
       `#if canImport(Security)`; the `SecretsStore` protocol and `InMemorySecretsStore`
       are platform-free, so off Darwin the in-memory store is the only one, which is what
       §2.3's table asks for. `SysctlProcessAncestry` answers from `/proc/<pid>/status`
       off Darwin, so the askpass ancestry rule is exercised on Linux too.
     - **`SSHProcess`**: `Platform.swift` wraps the four `Darwin.`-qualified libc calls;
       `ControlSocket`'s `$TMPDIR`, `isLiveSSH`, `liveMasterPIDs` and `commandLine` keep
       their `sysctl` on Darwin and read `/proc` elsewhere (`ProcFS.swift`); `Spawn`'s
       `posix_spawn` handles and `F_SETNOSIGPIPE` are branched;
       `IdentityAgentCheck` branches `SOCK_STREAM`'s type and `sun_len`.
     - **`AgentCore`** dropped `import FileProvider`. The capability and `fileSystemFlags`
       bitmasks are `ProviderCapabilities` and `ProviderFileSystemFlags` in
       `Sources/AgentCore/ProviderCapabilities.swift` - the file §2.2 puts in `ProviderCore`
       at step 1.3, where it moved verbatim on the same day; `AgentCore` now depends on
       `ProviderCore` for it. `BundleQuarantine`'s `getxattr` is Darwin's
       or nil. A macOS-only `MirroredProviderConstantsTests` asserts each mirrored bit
       against Apple's, which is step 4's `AppleConstantsTests` in miniature.

     **Next blocker (2026-09-08): none in the package - the compiler names nothing.** The
     next thing in the way is that `Apps/FileProvider` and `Apps/Agent` are still outside
     the package, so `swift test` cannot see them; that is step 1.3 (`ProviderCore`) and
     step 8 (`AgentRuntime`), not a port.

  3. **[x] Done 2026-09-08.** `ProviderCore`, and `Apps/FileProvider` down to five adapter
     files with no branch worth testing in them. The whole of the old extension moved:
     `Enumerators.swift` became `ProviderCore/ContainerEnumeration.swift` and
     `WorkingSetEnumeration.swift`, `IndexReaderStore.swift` became
     `ProviderCore/ReaderStore.swift` (its readiness rule already lived in
     `Index.IndexReaderReadiness`), `Item.swift`'s field-by-field copy became
     `ProviderCore/ItemView.swift`, and `FileProviderExtension.swift`'s decisions - the
     identifier mapping, the trash refusal in all three of its places, the working-set
     health counters and their `signalErrorResolved`, the reader/agent choice, the
     `currentAnchor` rule, the partial-fetch alignment, the agent-presence latch and the two
     Finder actions - became `ProviderCore/ProviderService.swift`.

     Protocols as §2.2 names them: `ProviderFailure`, `EnumerationObserving`,
     `ChangeObserving`, `ProviderEnumerating`, `AgentChannel`, `ReaderStoring`,
     `ProviderClock` and `ProviderDomainSignalling` (the three `NSFileProviderManager`
     calls the extension makes on its own domain). Beside them the neutral mirrors:
     `ProviderItemIdentifier` (with the three well-known container literals),
     `ProviderSyncAnchor`, `ProviderPageToken`, `ItemView`/`ItemTemplate`/`ItemChanges`,
     `ProviderCapabilities` and `ProviderFileSystemFlags` (moved from `AgentCore`
     verbatim), `ProviderItemFields`, `ProviderContentPolicy` and
     `ProviderContentTypeHint`.

     What is left under `Apps/FileProvider`: `FileProviderExtension.swift` (the
     `NSFileProviderReplicatedExtension` conformance, forwarding every call, plus the temp file
     only the appex can make), `Enumerators.swift` (an `NSFileProviderEnumerator` wrapper
     and the two observer adapters), `Item.swift` (`NSFileProviderItem` over an `ItemView`),
     `AgentConnection.swift` (the `NSXPCConnection`, the `AgentChannel` over it and the
     `NSFileProviderManager` half) and `AppleMapping.swift` (the one function each way
     between `ProviderFailure` and `NSError`, built from Apple's symbols and never from a
     number).

     `Tests/ProviderCoreTests/MirroredProviderConstantsTests.swift` is the macOS-only guard:
     one assert per mirrored constant - the three container identifier literals, ten
     capability bits, five `fileSystemFlags` bits, eleven `changedFields` bits (including
     the three the quirk table names as numbers) and every `ProviderFailure`'s domain and
     code. It found five wrong error codes the first time it ran, which is exactly the drift
     it exists for.
  4. **[x] Done 2026-09-08.** `SystemModel`: `VirtualClock` (nothing sleeps),
     `MacOSVersion`/`Quirk`/`QuirkMeasurement`/`QuirkTable` with the 26.4 and 26.6 columns
     and the "refuses to resolve an unmeasured id" rule, `Replica`, `ErrorThrottle`,
     `ModelAgent` (an `AgentChannel` over a **real** `IndexWriter`, so the fallback runs the
     same `IndexChangeStream` the agent does) and `FileProviderD`/`ModelDomain`. The rules,
     each citing its quirk id in the code: enumerate-once-ever (`MQ-001`), the working set as
     a change stream only (`MQ-002`), a fresh instance per signal (`MQ-003`), the
     empty-change-set-at-the-held-anchor counter (`MQ-004`), the fetch-event-stream throttle
     on the measured schedule and its dropped signals (`MQ-005`), anchor expiry re-asked from
     a fresh anchor (`MQ-006`), no timeout on a 60 s `enumerateItems` (`MQ-007`),
     `.noSuchItem` from `item(for:)` deleting the user's file (`MQ-011`), believing returned
     versions (`MQ-013`), `signalErrorResolved` as the only thing that lifts a backoff
     (`MQ-037`), and killing an idle instance (`MQ-073`). The throttle's curve is fitted
     through both measured points - 7 errors / 1 min 34 s and 27 errors / 47 min - and
     clamped to the measured 47 minutes at the threshold.
  5. **[x] Done 2026-09-08.** Scenarios **A1-A9** in `Tests/SystemModelTests`, eleven tests
     (A2 is three: the fixed behaviour, the bite-proof, and the recovery that makes the
     `signalErrorResolved` call).

  **Done when A2 fails on the 0.1.2 code and passes on today's - and it does.** A copy of
  the 0.1.2 working-set enumerator lives in the test file as
  `LegacyWorkingSetEnumeration` and is handed to fileproviderd through the model's
  `workingSetEnumeratorOverride`. Run `A2`'s own assertions against it and they fail:
  `backingOff(nextRetryIn: 2820.0)` against `.none`, 40 consecutive errors against 0, and
  0 of 40 rows in the replica against 40. Nothing in `Sources/` knows that copy exists.

  **Next: step 2**, the quirk machinery - the JSON mirror of `docs/quirks/`, the
  Markdown/JSON consistency test, `SSHDRIVE_MACOS` on the environment, and the A suite
  parameterised over the matrix. `SystemModel`'s table is already shaped for it; what it
  lacks is the mirror and the `check-quirks.sh` guard.

**Step 2 — the quirk machinery.** `Quirk`, `Measurement`, `MacOSVersion`, `QuirkTable`, the
JSON mirror, the "unmeasured quirk on a supported version fails loudly" rule, and the
Markdown/JSON consistency test. Parameterise the A suite over the matrix.

**Step 3 — [x] Done 2026-09-08. The rest of the extension**, driven by the model rather than
by a script. `SystemModel` grew the halves it had not had: the **write queue** (`PendingWrite`,
the `MQ-035` and `MQ-014` schedules, a fresh instance per offer, the pending-items set a
collision retry stays out of), the **download scheduler** (the six-fetch ceiling of `MQ-031`
against the all-admitted foreground opens of `MQ-032`, and no retry ever for a failure),
**eviction** (`MQ-017`-`MQ-021`, `MQ-024`, `MQ-030`, `MQ-033`, `MQ-034`, and the recursion of
`MQ-020`), the **deferred atime advance** (`MQ-022`), the **trash node** and its two answers
(`MQ-075`, `MQ-009`, `MQ-010`), the **replica lookup** that `MQ-029` says is the only thing
that starts an unseen path, `SystemModel.Finder` (the user: open, read, create, duplicate,
save, rename, `chmod`, tag, `setxattr`, `ln -s`, delete, walk and the contextual menu) and
`SystemModel.Launchd` (`MQ-061`-`MQ-063`). `ModelAgent` gained a real write path over the real
index, including section 5.7's own `SymlinkPolicy` check and the conflict copy of section 5.5.

  Scenarios: **B1-B3, C1, C2, D1, D2, D3, D4, D9, D12, F1, F2, F4, G1-G6, G8, G9, G13, G14,
  H9's system half, L3-L6, M3, M4, E3** and **P1, P2, P3, P5, P8**'s system halves - 48 tests
  in five files, of which six are bite-proofs against a copy of the old behaviour: the 0.1.2
  invalidation handler that disconnected the domain (`C1`), the un-retried eviction that leaves
  local bytes under a remote version (`D2`), atime back in the TTL's `max` (`G1`), the
  `.noSuchItem` trash answer that hangs the mount (`B1`), an item that returns no `tagData` and
  loses the user's tags (`L4`), and both misspellings of the activation-rule binding (`G14`).
  `C3`-`C6`, `D8` and `L7`/`L8` are not claimed.

**Step 4 — `AppleConstantsTests`.** The macOS-only target that asserts every mirrored constant
(capability bits, `fileSystemFlags`, error codes and domains, `changedFields` masks, the root
identifier literal, the trash identifier) still equals Apple's. One assert each; it is the only
thing that can drift silently.

  Two thirds of it exist already and want folding together, not rewriting:
  `ProviderCoreTests/MirroredProviderConstantsTests` (step 1.3) and
  `AgentRuntimeTests/MirroredAgentConstantsTests` (step 8: `SF_DATALESS`, the three eviction
  codes and the two Cocoa ones, `supportsSyncingTrash`'s default, the testing-mode bits and
  the `SMAppService.Status` cases). What step 4 adds is the single macOS-only *target* and
  the CI line that runs it.

**Step 5 — `ReplicaControlling` and the replica model.** `ReplicaAccess`,
`ReplicaEnumerators` and `DomainManager`'s File Provider calls behind the protocol;
`SystemModel.FileProviderD` grows the materialized and pending sets, the eviction rules and the
signals. Scenarios **F1-F6, G1-G9, P5, P6, P8**.

  **Half of this arrived with step 8 (2026-09-08):** the protocol exists, every one of those
  calls is behind it, and `AgentRuntimeTestSupport.FakeReplica` answers them well enough for
  **F6, G1, G4, G5, P8** and the F7-F10 group.

  **The other half arrived with step 3, later the same day.** `SystemModel.FileProviderD` now
  holds the materialized set, the pending set, the eviction rules, the download scheduler and
  the deferred atime, so **F1, F2, F4, G1-G6, G8, G9, P5 and P8** assert against measured
  fileproviderd behaviour rather than a scripted answer, and the two halves of `G1`, `G4`,
  `G5`, `P1`, `P2` and `P8` are keyed on the same quirk ids. Still owed here: **F3 and F5**
  (both `SV`, and both wanting `ServerModel`'s connection) and **P6**.

**Step 6 — [x] Done 2026-09-08. `ServerModel` v0: shells and exec channels.**
`Sources/ServerModel` is a package library target (`Logging`, `SFTP`, `SSHProcess`,
`XPCProtocols`) holding four things:

  - **`ServerProfile`** and `ServerQuirks`. Nineteen constants: the testbed's twelve
    services (`deb`, `deb-shells`, `deb-extsftp`, `deb-kbdint`, `deb-maxsess`, `alp`,
    `alp-ext`, `alp-nocmin`, `bastion-a`, `bastion-b`, `inner`, `ts-ssh`), the account
    variants that differ (`deb/pw`, `deb/keypass`, `bashbg`, `forcesftp`, `extquiet`), the
    **owner's own two servers** (`ownerDebian`, OpenSSH 9.2p1 Debian-2+deb12u10; and
    `ownerTailscale`, the Tailscale SSH node), an `openSSH9_6` shape, and the two the
    testbed cannot provide - `freeBSD` and `synologyDSM`. `SFTPExtensionSets` carries the
    three measured lists (`SQ-024`, `SQ-025`, `SQ-026`), and 9.2's and 9.6's are asserted
    to be *identical*, so only the identification string can tell them apart (`SQ-036`).
    `OpenSSHPrompts` carries the captured OpenSSH 10.2 prompt strings with their trailing
    spaces (`SQ-060`). `ServerQuirks.implemented` names every row keyed on, and
    `ServerProfileScenarios` asserts each one exists in `docs/quirks/servers.md` - the
    first of `scripts/check-quirks.sh`'s assertions, run from the suite until the script
    itself exists.
  - **`FakeSSHD` / `FakeExecChannel`**: an exec channel whose remote end is a **real**
    shell on the box. bash and zsh get their real rc mechanism (`BASH_ENV`, `ZDOTDIR`'s
    `.zshenv`), which is what `SQ-015` is actually about; dash and busybox ash, which read
    no rc for a script on stdin, get the same bytes ahead of the script. `bashbg`'s
    background child really holds stdout (`SQ-016`), a `ForceCommand` account answers with
    the plain sentence or SFTP framing (`SQ-013`), `MaxSessions` is counted across open
    channels (`SQ-021`), and the process-group policy is **real**: `.ownProcessGroup`
    spawns each session as its own group leader, `.sharedWith("tailscaled")` starts a
    long-lived leader and spawns every session into *its* group, so `kill -TERM 0` run by a
    real shell really does or does not reach a real bystander (`SQ-010`, `SQ-012`). A
    busybox profile gets a generated `find` shim that behaves the way BusyBox 1.36.1 was
    measured to - `-cmin`/`-printf` rejected rc 1, `--version` printing an error and
    exiting **0** (`SQ-001`-`SQ-003`).
  - **Scenarios**: `ShellScenarios` (J4, J5 ×2, J6, J7, N4), `HeartbeatScenarios`
    (J1 ×3 including the bite-proof, J2/J3), `SweepScenarios` (H1, H2, H3, H6).
  - **What skips, by name, on this box**: `busybox`, `fish` and `tcsh` are not installed,
    so the busybox-ash, fish and tcsh rc-noise rows print a named skip rather than a pass.
    The busybox **`find`** rows are not skipped - the flavour is modelled by the shim and
    the shell that runs the script is a real dash.
  - **And one that skips on macOS**: `J1`'s bite-proof needs a `kill -TERM 0` to reach a
    sibling in a shared process group. On Linux it does, and the pre-2026-09-08 wrapper
    kills the bystander exactly as `SQ-010` measured. On macOS 26.4 the sessions really are
    put in one foreign process group - the model asserts that before it starts - and the
    group signal reaches nothing but the sender's own child, so the row skips there with
    that sentence rather than passing for the wrong reason. This is a fact about the
    *harness* on Darwin, not about a server; the Linux job is the gate (§9), and the
    shipping wrapper's row - the child dies, the sibling lives - runs on both.

**Step 7 — [x] Done 2026-09-08. `ServerModel`: the SFTP wire and the fake `ssh`.**

  - **`FakeSFTPServer`** is a real SFTP v3 **wire** server over a `ByteStream`, with a
    codec of its own rather than a reuse of `SFTP`'s: a server that shares the client's
    encoder can only ever agree with it. `SFTPClient` and `RealSFTPTransport` run against
    it unmodified. The rules it applies are `SQ-024`-`SQ-034`: the profile's extension list
    in order and an unadvertised extension refused, `limits@openssh.com`'s measured values,
    status *classes* with no errno so `ENOSPC`/`EEXIST`/`ENOTEMPTY`/`EXDEV` are all a bare
    `FAILURE` with the literal message "Failure", the reversed `SSH2_FXP_SYMLINK` argument
    order, an `opendir` that **follows a symlink**, a `readdir` that carries attributes but
    no link target, `ETXTBSY` over a running executable, `mkdir` filtered by the umask,
    `posix-rename` versus a plain `rename` that does or does not overwrite, and case
    folding. `SFTP.FakeTransport` stays the fast in-memory double above the protocol, and
    `Tests/SFTPTests`' `InMemorySFTPServer` stays as the codec's own unit double; this is
    what the profile-driven transport scenarios use.
  - **`FakeSSH`** is a generated POSIX `sh` stub installed into `SSHProcess.sshBinaryPath`,
    not a built product: it is spawned by absolute path exactly as `/usr/bin/ssh` is, needs
    no build step and no product to locate, and lets each scenario script its own stderr
    and exit shape. It reproduces readconf's **first-setting-wins** rule (`SQ-038`), one
    round of percent expansion before `/bin/sh -c` (`SQ-039`), CRLF stderr (`SQ-035`), the
    identification string only at `DEBUG1` (`SQ-036`), the askpass prompts with the
    host-key question's missing hint (`SQ-047`, `SQ-060`, `SQ-062`), `-O check`/`-O exit`
    and a real AF_UNIX control socket where `python3` can bind one, the mux client's two
    stderr shapes for a refusal and for a dead master (`SQ-021`, `SQ-079`), sessions counted
    by process **state** rather than by pid so a zombie does not hold one open (`SQ-075`),
    `ControlPersist` forking away (`SQ-041`) and exit 255 with nothing on stderr for a
    signal-killed remote command (`SQ-011`).
  - **Scenarios**: `SFTPWireScenarios` (K12 ×2, N2 ×2, L1, M2, D7, J8, J11, and the
    `SQ-027`/`SQ-028`/`SQ-029` wire rules), `TransportScenarios` (K1, K2 ×2, K7 ×2, K9,
    K10, K11, K13/K14, N3/J12).
  - **Deferred, and not claimed**: K3-K6, K8, L2, L7, L8, M1, N1, J9, J10, J13, H4, H5,
    H7-H10. K5, K8, L2, M1, N1, H8 and H10 are pure-unit rows that belong beside their
    types; the rest need `AgentRuntime` (step 8) or the helper binary (step 9).

  **Counts.** **745 tests on this box** (was 700), 41 skipped, and **754 on the Mac** (was
  709), 42 skipped - the 45 new ones are `Tests/ServerModelTests`, and the Mac's extra skip
  is `J1`'s bite-proof, for the reason above. Nothing else moved on either platform.

  **Two test seams were added, both behaviour-preserving.** `SSHProcess.sshBinaryPath` is
  a settable `var` over `defaultSSHBinaryPath` (also readable from `SSHDRIVE_SSH_BINARY`,
  which is how a `ProxyCommand` hop the stub spawns finds the stub again); and
  `Spawn.run` gained `joinProcessGroup: pid_t?`, which is what lets a session be put into
  an *existing* group so `SQ-010` can be run rather than asserted. Nothing in the product
  passes either.

**Step 8 — `AgentRuntime`. [x] Done 2026-09-08.** Everything `Apps/Agent` decided is in the
package: `LocationRuntime` and its two extensions, `DomainManager`, `ChangeDetector`,
`CacheEvictor`, `IndexReconcile`, `ReconnectingTransport` with its `ConnectionGate`,
`SSHBackedTransport` with the new `SSHTransportLauncher`, `ChannelBudget`/`ChannelProbe`/
`CapabilityCache`, `HelperDeployer`, `HelperStream`, `HelperCleanup`, `CollectConnection`,
`LocationCommands`, `ControlCommands`, `TransportDebug`, `ConfigAccess`, `Deadline`,
`CallJournal`, `HandleSink`, `AgentSecrets` and `AgentSecretsDebug`, plus three types that
were a decision inline in an adapter: `AgentLifecycle` (the handover and unregister rules
without the dispatch sources), `PresenceOverride` (section 4.2's spike override, parsed) and
`ForcedNotReady`. `Apps/Agent` is **ten files and 2,009 lines**, down from 13,300, and none
of them holds a branch worth testing. Beside it `AgentRuntimeTestSupport`: `FakeReplica`
(recording every domain, signal, enumerator and eviction call, and scriptable for a refusal,
a missing manager or a 4099 that lands anyway), `FakeLoginItem`/`FakeLaunchd` (`MQ-062` and
`MQ-063` as state machines), `ScriptedPower`/`ScriptedNetwork`/`ScriptedPresence`/
`ScriptedScreenLock`, `ScriptedPeers`, `RecordingReaderPeers`, `FakeBundle`,
`RecordingEndpoint`, `FakeTransportLauncher` with `FakeLiveConnection` (over the existing
`SFTP.FakeTransport`, or over `ServerModel`'s channels through its `transportFactory` hook),
`VirtualAgentClock` and `AgentHarness`, which is one agent with a group container of its own.

  Scenarios, in `Tests/AgentRuntimeTests` (**16 tests**, all Linux, all in one `.serialized`
  tree because `GroupContainer`'s locator is process-wide): **F6** (sleep drops every master
  and no reconnect is scheduled; wake brings them back), **F7** (the reconnect runs
  `ReconnectSequence` in order and the flush cue precedes the working set), **F8** (a
  transient tier-2 failure is held for 2 s, not for the session, and climbs back on the next
  cycle), **F9** (four outages, and the hold after each reconnect is the 2 s one, never a
  compounded one), **F10** (section 4.2's two re-arm triggers and the once-a-minute presence
  rule), **D5** (30 held in bulk plus the directory held as an ancestor of a pending edit, a
  held fetch answering `.cannotSynchronize`, and `accept-deletions` scoped and whole),
  **G1** (280 s under a 60 s TTL evicted, with the atime read *before* the eviction and
  deciding nothing), **G4** (a pin inherited by every descendant with one marker, and the
  eviction refused with a sentence), **G5** (an explicit exclusion beating the pin above it),
  **K13**/**K14**'s cache half (the verdict on `ssh`'s own wording, and an abrupt loss
  making the cached budget suspect while leaving the values in the file for an offline
  `status`; step 7's `TransportScenarios` covers the same two against a real refused
  channel), **P1** (`register()` alone does not repair a
  replaced bundle; the handover waits for a whole one), **P2** (the unregister role polls
  launchd, not `SMAppService`, and gives up at 30 s) and **P8** (a nickname renames the
  domain in place, with the materialized set and the pending upload untouched).

  **The rest of step 8 landed later the same day**, in the pass that closed every remaining
  row whose harness is the agent fakes, the `ServerModel` or both. `Tests/AgentRuntimeTests`
  is 47 tests in nine files: `AddFlowScenarios` (the new suite **Q1-Q9**),
  `WriteScenarios` (**D2**, **D6**, **D10**, **D11**, **G10**), `DetectionScenarios`
  (**H8**, **H9**, **H10**, the new **H11**), `EvictionAndPinScenarios` (**G1** twice,
  **G2**, **G3**, **G4**, **G5**, the new **G11** and **G12**), `CapabilityScenarios`
  (**N1**, the new **N5**), `LifecycleScenarios` (**P1** twice, **P2**, **P4**, **P8**,
  **P9**), `ReconnectScenarios` (**F5**-**F11**), `GuardScenarios` (**D5**) and
  `ProbeScenarios` (**K13**, **K14**). `Tests/ServerModelTests` gained
  `MasterScenarios` (**K3**-**K6**), `HelperShellScenarios` (**J9**, **J10**, **J13**),
  `NamesAndAttributesScenarios` (**L7**, **L8**), **H4**, **H5** and **H7** in
  `SweepScenarios` and the new **J14** in `ShellScenarios`.

  Three seams were added for it, all additive and all behaviour-preserving: `SweepWindow`
  `.forCycle`, `SweepPlan.partitionRoots` and `RemoteSweep.collect` in `AgentCore` (the
  window, the `./name`/non-UTF-8 argv rule and the sweep read loop, so `ChangeDetector`
  calls them instead of holding copies), `PollSchedule.paces`, `ExecChannel.reportDeath`
  in `SSHProcess` and `ControlSocket`'s state-aware liveness (`SQ-075`: a zombie is not a
  live master), and `AgentRuntimeTestSupport.ScriptedTerminal`/`AskpassBridge` - a real
  `sshdrive-askpass`-shaped program with a file mailbox where the XPC connection is, so
  section 4.2's token protocol runs for real off a Mac.

  Still owed to this step and not claimed: **D4**, **D8** and **E1**, **E3-E6** (the index
  half and the two rows that want a bundle replacement under a live queue), which are
  `SystemModel`'s. **E2 landed on 2026-09-09**, as `ListingScenarios` in
  `Tests/AgentRuntimeTests`: `SQLiteConnection.statementObserver` is the seam, and the two
  halves are what one listing writes and what its transaction holds while it writes it. A
  **third half** landed the same day with the index's statement cache: what a large listing
  *compiles*. `SQLiteConnection.compileObserver` is that seam - it fires only when
  `sqlite3_prepare_v2` actually runs - and the assertion is that a 2,000-entry listing
  compiles a handful of statements rather than 8,006, takes no savepoint per anchor, and
  never asks `SELECT last_insert_rowid()`.
  **E7 landed on 2026-09-09** beside it, in `Tests/AgentRuntimeTests/LargeListingScenarios.swift`:
  the same questions at ten thousand entries and over the wire, with the `item(for:)`
  storm and the working-set replay on the other side of the index. It counts the wire
  round trips, the compilations, the statement executions per entry, the `readlink`s and
  the log lines, prints what each phase took, and guards the clock only loosely - the
  numbers move with the box, the counts do not.

  **Three bugs the models themselves had, all found by a scenario and all fixed.** They are
  worth naming because a simulator that is wrong is worse than no simulator: `FakeSFTPServer`'s
  `readdir` announced the size of the **page** and then skipped any entry whose node had gone
  since `opendir`, so our own stale-temp sweep removing a `.sshdrive-upload-*` mid-listing
  produced a `SSH_FXP_NAME` promising more entries than it held - the client read into the next
  packet and the channel died `badMessage` a millisecond after coming up, which is exactly what
  a real server can never do. `FakeSFTPStream` handed a parked reader **everything** it had
  rather than the `upTo:` it asked for, and left a satisfied read's deadline timer armed to
  fail whichever *later* read happened to be parked when it fired. Each of the three surfaced
  as a location that connected and immediately went offline, in a different scenario every run;
  none of them was a product fault, and all three would have been read as one.

  Beside them `Tests/AgentRuntimeTests/MirroredAgentConstantsTests.swift`, the macOS-only
  guard on everything the agent's adapters mirror, in the shape step 1.3 gave the
  extension's: `SF_DATALESS`; the three eviction codes S4 measured **including the two that
  are never seen**, because "we never see it" is the finding (`MQ-017`-`MQ-019`); the two
  Cocoa codes the reports carry (`MQ-019`, `MQ-052`); that `supportsSyncingTrash` still
  defaults to YES, which is why the adapter clears it (`MQ-008`); the two testing-mode bits;
  and the four `SMAppService.Status` cases behind `doctor`'s login-item line.

**Step 9 — the helper. [x] Done 2026-09-08** for `J9`, `J10` and `J13`, in
`Tests/ServerModelTests/HelperShellScenarios.swift`: the **real** Rust binary is copied onto
the model server and run through a real exec channel, a byte is flipped in it **in place**
(same size, same inode), and both the `sha256sum` route and the `--version` self-digest route
catch it - which is `SQ-067`'s point that a hash the build *embeds* cannot be the hash of that
binary, bite-proved with a stand-in that embeds one. `ETXTBSY` over the running copy and the
temp-name-and-rename that gets past it are `J10`. `J11` is already covered on the wire; the
Tailscale process-group model is `J1`, done at step 6.

**Step 10 — lifecycle seams. [x] Done 2026-09-08** except `P7`, which is `release.sh` and a
certificate and has nothing to simulate (section 7). Every protocol is in place and both
halves are covered: `Tests/AgentRuntimeTests/LifecycleScenarios.swift` for what the *agent*
decides against `FakeLoginItem`/`FakeLaunchd`/`RecordingEndpoint` (**P1**, **P2**, **P4**,
**P8**, **P9**), `Tests/SystemModelTests/LifecycleScenarios.swift` for what launchd,
`SMAppService` and LaunchServices do to it (**P1**, **P2**, **P3**, **P5**, **P8**), keyed on
the same `MQ-061`-`MQ-063`.

**Step 11 — the seeding apparatus.** `docs/spikes/macos-version-sweep.md` (the runbook that
measures every quirk on a new OS in one session), the §6.3 checklist wired into
`docs/release.md`, and the CI shape below.

**Step 12 — retire the ad-hoc proofs.** Every "proved on the VM" claim in the milestone list
that a scenario now covers gets the scenario id beside it, and the VM runbooks shrink to §7's
list.

## 9. (h) Running it

### On this Linux box

```sh
. ~/.local/share/swiftly/env.sh
cd Packages/SSHDriveCore
swift test                                  # everything, at the default macOS version
SSHDRIVE_MACOS=14.7 swift test              # one version
SSHDRIVE_MACOS=14.7,15.6,26.4,26.6 swift test --filter ScenarioTests
cd ../../helper && cargo test && cargo clippy -- -D warnings
```

No Mac, no VM, no network, no testbed, no `docker compose`. The testbed-backed tests keep their
existing `SSHDRIVE_TESTBED=1` gate and are skipped.

`Package.swift` keeps `platforms: [.macOS(.v14)]` (it constrains the macOS build only) and gains
the seven new targets. Every target must compile for Linux; that is enforced by the Linux job,
not by convention.

### On the Mac

The **same** `swift test` runs on the build VM and must be green there too. It is not a second
suite: it is the same scenarios against a different box, and a row that cannot run there skips
by name rather than being branched out.

```sh
rsync -a --delete --exclude .git --exclude helper/target ./ alec@100.114.204.5:sshdrive/
ssh alec@100.114.204.5 'cd ~/sshdrive/Packages/SSHDriveCore && swift test'
```

As of 2026-09-08: **813 XCTest with 41 skipped and 51 swift-testing here, 827 XCTest with 45
skipped and the same 51 on Darwin.** The extra fourteen are the macOS-only mirrored-constant
assertions; the Darwin-only skips are `H7` (`SQ-080`, APFS will not hold the name), `J10` and
`J1`'s bite-proof. There is **no `timeout` on macOS** and none of the shells the runbooks
assume, so a long run is started detached on the VM and polled.

### What `Apps/` still needs a Mac for

Only compiling and signing. After the migration the four shells contain adapters and Info.plists
and nothing else, so a macOS job that builds them is a compile check on the Apple type-mapping —
which is exactly the risk that remains once the logic has moved. `xcodegen generate` then
`xcodebuild -configuration Debug` and `-configuration Release` for `SSH Drive`, `sshdrive`,
`sshdrive-askpass` and `SSHDriveFileProvider`, plus `swift test --filter AppleConstantsTests`
(today: `--filter Mirrored`, which catches both mirrored-constant suites).

### CI

```yaml
jobs:
  linux:                         # ubuntu-24.04, the whole suite, the only job that tests
    strategy: { matrix: { macos: [14.7, 15.6, 26.4, 26.6] } }
    steps:
      - swift test                                   # SSHDRIVE_MACOS=${{ matrix.macos }}
      - cargo test --manifest-path helper/Cargo.toml
      - cargo clippy --manifest-path helper/Cargo.toml -- -D warnings
      - scripts/check-quirks.sh                      # Markdown ids == JSON ids == referenced ids
  macos:                         # macos-15, build only
    steps:
      - xcodegen generate
      - xcodebuild -configuration Debug   build
      - xcodebuild -configuration Release build
      - swift test --filter AppleConstantsTests
  helper:                        # unchanged: .github/workflows/helper.yml
```

The Linux job is the gate. The macOS job proves the shells still compile and the mirrored
constants still match; it runs no scenario, because a scenario that needs a Mac is a scenario we
have failed to encode.

`scripts/check-quirks.sh` is the third guard: every quirk id in `docs/quirks/` appears in the
JSON, every id the model reads exists in the catalog, and every scenario id referenced by a
quirk exists in `Tests/ScenarioTests/`. That is what stops the catalog becoming decoration.
