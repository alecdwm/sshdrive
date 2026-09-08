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

**2026-09-08: `Logging` is ported** (§8 step 1.1), so the build now reaches `XPCProtocols` and
`Config` — the two modules directly above it, which fail in parallel. The walk continues from
there.

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
  XPCProtocols/     value types only, no @objc
  XPCInterfaces/    NEW, macOS-only: the @objc protocols, NSXPCInterface whitelists,
                    SecStaticCode peer requirement. Referenced only from Apps/.
  ProviderCore/     NEW: everything Apps/FileProvider decides
  AgentRuntime/     NEW: everything Apps/Agent decides
  SystemModel/      NEW: simulated fileproviderd + Finder + launchd, quirk-driven
  ServerModel/      NEW: simulated ssh, sftp-server, shells and find flavours
```

### 2.2 The extension's seams (`ProviderCore`)

Today `Apps/FileProvider` is five files and all five are logic wearing an Apple coat. The
split:

| Today | Moves to | Left in `Apps/FileProvider` |
|---|---|---|
| `Enumerators.swift` (275 lines) | `ProviderCore/ContainerEnumeration.swift`, `ProviderCore/WorkingSetEnumeration.swift` | two `NSFileProviderEnumerator` adapters that wrap the system's observers and forward |
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

## 4. (c) `ServerModel`: the remote half

`ServerModel` is the second package library target: a whole SSH/SFTP server universe in
process, plus the parts that are honest to run for real on Linux.

### 4.1 `ServerProfile`

One value describes a server, and the testbed's twelve services are twelve constants:

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

| Id | Name | Setup | Action | Assertion | H |
|---|---|---|---|---|---|
| B1 | The `.Trash` materialize loop | A fresh domain | The system creates its trash node and asks `enumerator(for: .trashContainer)` | The provider answers `NSFeatureUnsupportedError`, **never** `.noSuchItem`; the model gives up after two attempts and removes `.Trash`; a `stat` of `.Trash` returns | S |
| B2 | `supportsSyncingTrash = false` alone is not enough | Domain added with the flag off | Same | The trash node is still created and still asked about twice; the error code is what retires it | S |
| B3 | A `.Trash` create under the root is refused | — | `createItem(filename: ".Trash", parent: .rootContainer)` | Refused feature-unsupported, and nothing is sent to the server | S |

### Suite C — extension lifecycle and XPC

| Id | Name | Setup | Action | Assertion | H |
|---|---|---|---|---|---|
| C1 | Disconnect-in-invalidation | A provider instance with a live agent channel | The system kills the idle instance; the channel invalidates | The domain is **not** disconnected; the next instance's `indexReady` calls `reconnect()` unconditionally | S |
| C2 | A reader error is `.serverUnreachable` | The index file made unreadable | `item(for:)` | `.serverUnreachable`, never `.noSuchItem`; the replica keeps the user's file | S |
| C3 | The listener picks the interface by peer | Peers claiming to be `sshdrive`, `sshdrive-askpass`, the appex | Each connects | CLI gets `SSHDriveCLIProtocol`, askpass the one-method interface, everyone else the extension's | U |
| C4 | A stranger is dropped | A peer whose identity fails the requirement | It connects | The listener drops it; the error is "cannot reach the agent", not a partial service | U |
| C5 | An agent error survives the trip | An error with a `LocalizedError` description | It is returned over `AgentChannel` | The description survives in `userInfo`; the CLI prints the sentence, not `error 1` | U |
| C6 | A stalled replica call must not wedge the agent | `ReplicaControlling` made to hang for 3 minutes | Any other agent command | It answers within its own deadline; nothing queues behind the replica call | S |

### Suite D — writes, conflicts, atomicity

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

### Suite E — the index

| Id | Name | Setup | Action | Assertion | H |
|---|---|---|---|---|---|
| E1 | Nested transactions | A listing whose body appends anchors and deletes rows | One listing | No `cannot start a transaction within a transaction`; inner levels are `SAVEPOINT`s; an inner failure caught by its caller undoes only its own writes | U |
| E2 | A 10,000-entry listing is one transaction | A directory with 10,000 entries | Enumerate it | One `BEGIN IMMEDIATE`, one commit; the enumeration completes | U |
| E3 | Sorted keys in the attributes blob | A six-key `LocalAttributes` | Encode it 200 times in one process | Byte-identical every time; the metadata version does not move on its own | U |
| E4 | A local-only row survives | A `.DS_Store` local-only row | A listing that does not mention it | The row and the user's bytes survive | U |
| E5 | The reconcile always clears its flag | A corrupt index | Restore into the live database, then a walk that hits its deadline | The restore goes through the backup API (the sidecars and the open reader keep their inode); `meta.reconciling` is cleared even on the deadline path; the walk runs after `add(domain)`, not inside `start()` | S |
| E6 | `held.dir` follows a rename | A held deletion under a directory | Rename the directory | Both `held.path` and `held.dir` are rewritten; the 5- and 30-minute re-checks resolve | U |

### Suite F — offline, the breaker, reconnection

| Id | Name | Setup | Action | Assertion | H |
|---|---|---|---|---|---|
| F1 | `signalErrorResolved` is the only flush | A queued write, the backoff past five minutes | Reconnect with no signal; then `signalEnumerator`; then `signalErrorResolved` | Nothing, nothing, then the `modifyItem` within 20 ms | S |
| F2 | No system retry for a fetch | A `fetchContents` answered `.serverUnreachable` | Wait | No second call, ever; a second read produces a second call | S |
| F3 | A dead connection is retried once | A silently dead master | One read | It succeeds on the retry through the breaker; a **write** is not retried this way | SV |
| F4 | A queued write is re-offered for ever | A faulted write | Twelve minutes of model time | The doubling schedule is followed and never gives up; each retry lands on a fresh instance | S |
| F5 | A call waits for the attempt in flight | Two reads three seconds apart during a 20 s connect | Both | Both wait for the one attempt and both succeed, bounded by that attempt's own remaining deadline, not 60 s from now | SV |
| F6 | Sleep drops, wake reconnects | Two locations, masters up | will-sleep, then did-wake | Both masters dropped by `-O exit`, no reconnect scheduled, the message acknowledged within the 5 s cap; new masters after wake | SV |

### Suite G — eviction and pinning

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

### Suite H — change detection

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
| H10 | A cycle that eats its interval | A 56.8 s cycle against a 60 s interval | The next schedule | The interval becomes three times the last cycle, capped at the insurance interval, and `status` says so; a tier-2 cycle that went nowhere paces nothing | U |

### Suite J — remote execution and the helper

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
| J13 | The exec channel dies 255 with no stderr | A remote command killed by a signal | Read the exit | Classified as the wrapper's death, not as the mux client's error | V |

### Suite K — transport and `ssh`

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
| K12 | The server is identified | `.tailscaleSSH` and `.debian` | `add` | The identification string is taken from the collect connection at `DEBUG1` and the `debug1:` lines stripped before the classifier; the extension fingerprint names Go `pkg/sftp` or OpenSSH; "not OpenSSH" and "not identified" stay different answers | V |

### Suite L — paths, names and attributes

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

| Id | Name | Setup | Action | Assertion | H |
|---|---|---|---|---|---|
| M1 | The lexical containment check | Links to `note.txt`, `/home/alec/m4/Other`, `/etc/passwd`, under both root spellings | List | Relative in-root shown, absolute in-root rewritten relative, escaping omitted with a reason, and the check holds under the canonical and the user-typed root | U |
| M2 | A `readlink` per link | A listing with links | Enumerate | One `readlink` per link, because SFTP v3's `readdir` carries no target | V |
| M3 | A refused `ln -s` is a sync error | An escaping target created in the mount | `createItem` | The create succeeds locally, the refusal comes back as the item's `uploadingError`, and the sentence reaches the user only through `status` | S |

### Suite N — the capability report and probes

| Id | Name | Setup | Action | Assertion | H |
|---|---|---|---|---|---|
| N1 | Never blame a server for our state | A helper still deploying | `add` | The report says `deploying` with no `upgrade:` line; "the server cannot run the remote helper" is reachable only from a real refusal | U |
| N2 | A cached probe keeps its extensions | A cached probe with no live connection | Build the report | The recorded extension set is used, never an empty default; four lines do not silently degrade | U |
| N3 | The `MaxSessions` probe | `.debianMaxSessions` | Probe | It asks "may I hold three at once", proves each by completing the SFTP handshake, drops the bulk channel at 2 and keeps the exec channel | V |
| N4 | A shell-less account | `.debianShells` `forcesftp` | Probe | "no shell access (ForceCommand)", never "shell output unusable", whether the account answers with SFTP framing or with a plain sentence | V |

### Suite P — packaging and lifecycle

These are the ones whose ground truth is a Mac. Each scenario asserts the **state machine** on
Linux and names the VM runbook step that measures the fact behind it (§7).

| Id | Name | Setup | Action | Assertion | H |
|---|---|---|---|---|---|
| P1 | The login item after a replacement | A registered job; the bundle deleted and replaced | `register()` alone, then `unregister()` + launch | `register()` alone does not repair it; only the unregister path does | VM |
| P2 | `unregister` waits for launchd | A job launchd has not yet dropped | Back-to-back unregister/register | The `unregister` role polls until the service is gone; a `register()` inside the window is asserted to leave a job dying on a 10 s throttle for ever | VM |
| P3 | A quarantined bundle registers no plugin | Quarantine xattr present | The postflight | `spctl --assess`, then the xattr strip, then unregister and `open -g`; `doctor`'s `quarantine` check is ordered ahead of "extension registered" | VM |
| P4 | SIGTERM exits 0 | The agent running with masters | `kill -TERM` | The same shutdown as `agent stop` runs, every master goes, and the exit status is 0 so `KeepAlive` does not restart the old bundle | S |
| P5 | `add(domain)` 4099 after landing | A replica that reports 4099 *after* the call succeeded | `add(domain)` | The domain list is re-read before the error is believed, and the discrepancy is logged | S |
| P6 | Stranded domains are removed | A domain no `config.json` claims, and a missing `config.json` | First start | Both are removed, with their `~/Library/CloudStorage` directories | S |
| P7 | The profile names the signing certificate | A profile issued for another certificate | `release.sh` | The hashes are compared **before** signing; the mismatch is named, the entitlement dropped loudly, and the build carries on | VM |
| P8 | A nickname renames in place | 4 materialized items, 1 pending upload | `set nickname` | The mount directory is renamed, the materialized set and the pending upload are unchanged, nothing is re-fetched, and the pending write still flushes | S |
| P9 | `add` waits for the first deployment | A location whose helper is being deployed | `add` | The upload sentence is printed first, then the report after a bounded wait; `status` ten seconds later agrees with it | S |

**Counts:** A 9, B 3, C 6, D 9, E 6, F 6, G 9, H 10, J 13, K 12, L 8, M 3, N 4, P 9 = **107
scenarios**, of which 5 are `VM`-anchored and the other 102 run on Linux with nothing attached.

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

- [ ] Add the version to `MacOSVersion` and to the CI matrix.
- [ ] Run `docs/spikes/macos-version-sweep.md` on a VM of that version against the testbed.
- [ ] Write the dated `results.md` entry.
- [ ] Walk **every** quirk in `docs/quirks/macos.md` and record a value: confirmed, changed, or
      not measured. Not-measured is a legitimate answer and shows as an empty cell.
- [ ] For each changed value, add a measurement row and let the model branch on it.
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

**Servers we do not have.** A real BSD `find`; FreeBSD kqueue and the helper's FreeBSD target
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
  2. **Next blocker (2026-09-08):** `Logging` now compiles on Linux and the build stops at the
     two modules directly above it, `XPCProtocols`
     (`Sources/XPCProtocols/AgentProtocol.swift:15:2: error: Objective-C interoperability is
     disabled`, at `@objc public protocol SSHDriveAgentProtocol`) and `Config`
     (`Sources/Config/GroupContainer.swift:43:29: error: value of type 'FileManager' has no member
     'containerURL'`). `swift build` again and fix what it names next, module by module, in
     dependency order:
     `XPCProtocols` (split the `@objc`/`NSXPCInterface`/`SecStaticCode` half into a macOS-only
     `XPCInterfaces` target), `Config`, `Index` (a `CSQLite` system-library target with a module
     map so `import SQLite3` becomes portable), `SFTP`, `Secrets` (`SecretsStoring` protocol +
     `#if canImport(Security)` keychain impl; `ProcessAncestry` behind
     `ProcessAncestryReading`), `SSHProcess` (`#if canImport(Darwin)` around the imports),
     `AgentCore` (drop `import FileProvider` from `ItemDerivation` and `RowBuilder`).
     Agents can now iterate here directly: `. ~/.local/share/swiftly/env.sh && swift build` and
     `swift test` work on this box for every module that compiles.
  3. `ProviderCore` with `ProviderFailure`, `EnumerationObserving`, `ChangeObserving`,
     `AgentChannel`, `ReaderStoring`, `ItemView`; move the bodies of `Enumerators.swift` and
     the decision half of `FileProviderExtension.swift` into it; leave adapters in
     `Apps/FileProvider`.
  4. `SystemModel` v0: the domain, the replica, the anchor bookkeeping, the fresh-instance-
     per-signal rule, the empty-change-set rule and **the error throttler with the measured 27/47
     schedule**.
  5. Scenarios **A1-A9**, plus `MQ-001` to `MQ-007` in the catalog.

  Done when A2 fails on the 0.1.2 code and passes on today's.

**Step 2 — the quirk machinery.** `Quirk`, `Measurement`, `MacOSVersion`, `QuirkTable`, the
JSON mirror, the "unmeasured quirk on a supported version fails loudly" rule, and the
Markdown/JSON consistency test. Parameterise the A suite over the matrix.

**Step 3 — the rest of the extension.** `item(for:)`, `fetchContents`/`fetchPartialContents`,
`createItem`/`modifyItem`/`deleteItem`, the trash, `performAction`, `decorations`, the error
table. Scenarios **B1-B3, C1-C6, D1, D3, D9, L3-L6, M3**.

**Step 4 — `AppleConstantsTests`.** The macOS-only target that asserts every mirrored constant
(capability bits, `fileSystemFlags`, error codes and domains, `changedFields` masks, the root
identifier literal, the trash identifier) still equals Apple's. One assert each; it is the only
thing that can drift silently.

**Step 5 — `ReplicaControlling` and the replica model.** `ReplicaAccess`,
`ReplicaEnumerators` and `DomainManager`'s File Provider calls behind the protocol;
`SystemModel.FileProviderD` grows the materialized and pending sets, the eviction rules and the
signals. Scenarios **F1-F6, G1-G9, P5, P6, P8**.

**Step 6 — `ServerModel` v0: shells and exec channels.** `ServerProfile`, `FakeExecChannel`
over real `dash`/`bash`/`busybox ash`, the rc-noise and sentinel shapes, the heartbeat wrapper,
`MaxSessions`, session process-group policy. Scenarios **J1-J8, J12, J13, N3, N4**.

**Step 7 — `ServerModel`: the SFTP wire and the fake `ssh`.** `FakeSFTPServer` over the same
`ByteStream`; the `FakeSSH` stub binary behind `TransportLauncher`. Scenarios **K1-K12, L1, L2,
L7, L8, M1, M2, D7, N1, N2**.

**Step 8 — `AgentRuntime`.** Move `LocationRuntime` and its two extensions, `ChangeDetector`,
`CacheEvictor`, `IndexReconcile`, `ChannelBudget`, `ReconnectingTransport`,
`SSHBackedTransport`, `CollectConnection`, the `DomainRegistry` half of `DomainManager` and the
command handlers. Scenarios **D2, D4-D6, D8, E1-E6, H1-H10**.

**Step 9 — the helper.** The Rust binary already builds and tests on this box; run it against
`FakeExecChannel` for real. Scenarios **J9-J11**, and the Tailscale process-group model.

**Step 10 — lifecycle seams.** `LoginItemControlling`, `LaunchdControlling`, `PowerObserving`,
`NetworkPathObserving`, `PresenceReading`, `ScreenLockObserving`, `BundleInspecting`, and
`SystemModel.Launchd`. Scenarios **P1-P4, P7, P9**.

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

### What `Apps/` still needs a Mac for

Only compiling and signing. After the migration the four shells contain adapters and Info.plists
and nothing else, so a macOS job that builds them is a compile check on the Apple type-mapping —
which is exactly the risk that remains once the logic has moved. `xcodegen generate` then
`xcodebuild -configuration Debug` and `-configuration Release` for `SSH Drive`, `sshdrive`,
`sshdrive-askpass` and `SSHDriveFileProvider`, plus `swift test --filter AppleConstantsTests`.

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
