# SSH Drive

A no-GUI macOS app that mounts remote SFTP locations into Finder through Apple's File Provider
framework (like Mountain Duck / iCloud Drive). Files are dataless placeholders until opened; cached
content is TTL-evicted unless pinned; mounts survive reboot, sleep and network loss; auth is whatever
the user's own `ssh` already does. Everything is driven by the `sshdrive` CLI. The design lives in
`docs/design/` (22 pages); this file is the map to it, not a replacement.

## Hard facts (do not get these wrong)

| Thing | Value |
|---|---|
| Team ID | `RWGDZAYBM8` |
| App bundle | `org.shirls.sshdrive` (`SSH Drive.app`, `LSUIElement = true`) |
| File Provider appex | `org.shirls.sshdrive.fileprovider` |
| Agent launchd label | `org.shirls.sshdrive.agent` |
| CLI / askpass signing ids | `org.shirls.sshdrive.cli`, `org.shirls.sshdrive.askpass` (explicit; a bare tool defaults to its product name and would fail the agent's code requirement) |
| App group = keychain access group | `RWGDZAYBM8.org.shirls.sshdrive` |
| XPC mach service | `RWGDZAYBM8.org.shirls.sshdrive.agent` (app-group prefixed so the sandboxed appex may connect) |
| `os.Logger` subsystem | `org.shirls.sshdrive`; categories `extension` `agent` `cli` `sftp` `ssh` |
| Group container | `~/Library/Group Containers/RWGDZAYBM8.org.shirls.sshdrive/` -> `config.json`, `domains/<location-id>/index.sqlite`, `capabilities.json`, `pins.json` |
| Repo / cask | `github.com/alecdwm/sshdrive`; cask `sshdrive` in tap `alecdwm/tap` (`alecdwm/homebrew-tap`). The cask **file** must be `Casks/sshdrive.rb`: Homebrew resolves the token to the basename |
| Version | one number for the whole product in `VERSION` at the repo root, stamped everywhere else by `scripts/set-version.sh` |
| Release signing | Developer ID Application `6C055553C6A361398A3CC48654E1FADC14660D05` (cert `T9DF89U2YU`), profile `~/Developer/SSH_Drive_Developer_ID.provisionprofile` on the VM, notarization by App Store Connect API key `~/Developer/AuthKey_*.p8` |
| `keychain-access-groups` | only satisfied when the embedded profile was issued for the signing certificate (gotcha 91). `release.sh` compares the two and, if they disagree, drops the entitlement with a loud warning so the build still runs - without stored passwords or key passphrases, and `doctor` says so |
| Domain identifier | the location's UUID |

Platform facts a coder must respect (`docs/design/platform.md`): minimum macOS **14** (develop/test on
14/15). The appex is sandboxed, ephemeral, has **no network entitlement** and cannot reach `~/.ssh`,
`SSH_AUTH_SOCK` or spawn processes. `NSFileProviderReplicatedExtension`; one `NSFileProviderDomain`
per location, mounted under `~/Library/CloudStorage/`. `item(for:)` is called constantly and must be
answered from local state. `keychain-access-groups` is a restricted entitlement needing a
provisioning profile, which only a bundle can embed - so the agent (the bundle's main executable) is
the only process with keychain access. `evictItem` evicts a directory recursively and works on the
root container too (measured on macOS 26.4, 2026-09-04); the TTL loop still goes file by file because
a TTL is per file. SFTP v3 carries nine status codes and no errno.

## Processes and modules

- **Agent** (`Contents/MacOS/SSH Drive`, the host executable): `SMAppService` login agent, not
  sandboxed. Owns `ssh`, SFTP, the index (sole writer), change detection, eviction, domain lifecycle,
  keychain, and the XPC server. Everything of consequence lives here.
- **Extension** (`Contents/PlugIns/SSHDriveFileProvider.appex`): thin XPC client, no state, no
  sockets; reads `index.sqlite` read-only for `item(for:)` and the working set only.
- **CLI** (`Contents/MacOS/sshdrive`): pure XPC client; even `add` connects from the agent.
- **askpass** (`Contents/MacOS/sshdrive-askpass`): pure XPC client, holds nothing, relays `ssh` prompts.
- **helper**: static Rust binary shipped in `Contents/Resources/helper/`, uploaded to the server
  (tier 2 of `docs/design/change-detection.md`).

`Apps/FileProvider` is six adapter files (979 lines) and `Apps/Agent` eleven (2,012 lines): they
translate to and from Apple's types and decide nothing. **No branch worth testing may live under
`Apps/`** - a new rule belongs in `ProviderCore` or `AgentRuntime` with a scenario beside it.

`Packages/SSHDriveCore/Sources`:

| Module | What is in it |
|---|---|
| `Config` | `config.json`, the location model, `GroupContainerLocating`, `SSHDriveVersion` |
| `Secrets` | keychain store (behind `#if canImport(Security)`), askpass token protocol |
| `SSHProcess` | the `ssh` command lines, master/mux management, exec channels, `ByteStream` |
| `SFTP` | the SFTP v3 wire client, `RelativePath`, `HelperDirectory`/`HelperFile` |
| `Index` | the SQLite index over `CSQLite`, writer and read-only reader |
| `XPCProtocols` | the platform-free half of the protocols, `AskpassEnvironment` |
| `XPCInterfaces` | macOS-only: the `@objc` NSXPC half the Apps link |
| `AgentCore` | the pure decision types: breaker, root set, sweep plan and parser, ladder, guard, poll schedule, eviction plan, pin policy, helper manifest/deployment/protocol, capability report, reconnect sequence |
| `ProviderCore` | everything the extension decides - enumerators, the working-set change path and its fallback, the reader store and its readiness window, item construction, the trash contract, decorations, the two Finder actions - behind `ProviderFailure`, `EnumerationObserving`, `ChangeObserving`, `AgentChannel`, `ReaderStoring`, `ProviderClock`, `ProviderDomainSignalling`, and mirrors of Apple's identifiers, capabilities, flags, fields and error codes |
| `AgentRuntime` | everything the agent decides - `LocationRuntime` and its extensions, `DomainManager`, `ChangeDetector`, `CacheEvictor`, `IndexReconcile`, `ReconnectingTransport`/`ConnectionGate`, `SSHBackedTransport`, the channel budget and its cache, the helper's deployment and stream, the collect connection, the CLI command handlers - behind `ReplicaControlling`, `LoginItemControlling`, `LaunchdControlling`, `PowerObserving`, `NetworkPathObserving`, `PresenceReporting`, `ScreenLockObserving`, `PeerIdentifying`, `IndexReaderPeering`, `BundleInspecting`, `KeychainDiagnosing`, `TransportLauncher`, `TerminalRelaying`, `AgentEndpoint`, `AgentClock`, all carried in one `AgentEnvironment` |
| `AgentRuntimeTestSupport` | an in-memory implementation of every one of those seams, plus `AgentHarness` and a driven clock |
| `SystemModel` | the simulated fileproviderd: quirk-driven, virtual clock, a replica the scenarios drive |
| `ServerModel` | the simulated server: a `ServerProfile` per testbed service and per real server of the owner's, `FakeSFTPServer` speaking SFTP v3 on the wire over a `ByteStream`, `FakeExecChannel` running a **real** local shell under the profile's rc noise and process-group policy, and `FakeSSH`, the stub that stands in for `/usr/bin/ssh`; every rule keyed on a row of `docs/quirks/servers.md` |
| `Logging` | the logging facade; `os.Logger` on Darwin |

## Repo layout

`VERSION` · `project.yml` (xcodegen spec at root; `xcodegen generate`, then `xcodebuild`) ·
`Packages/SSHDriveCore/` · `Apps/Agent/` (host exe `SSH Drive`, plus `Assets.xcassets` with the app
icon) · `Apps/FileProvider/` (appex) · `Apps/CLI/` (`sshdrive`) · `Apps/Askpass/`
(`sshdrive-askpass`) · `Resources/LaunchAgents/org.shirls.sshdrive.agent.plist` (must land at
`Contents/Library/LaunchAgents/` in the bundle) · `Resources/icon/sshdrive.svg` (the source the icon
set is rendered from) · `helper/` (the `sshdrive-helper` Rust crate; `cargo test` runs on this Linux
box, `scripts/build-helper.sh` emits `Resources/helper/` which `mac-build.sh` copies into the bundle,
and neither is in git) · `scripts/` (`set-version.sh`, `render-icon.sh`, `build-helper.sh`,
`mac-build.sh`, `release.sh`) · `.github/workflows/` (`helper.yml` cross-compiles the helper,
`release.yml` builds and publishes a tag, `pages.yml` deploys the docs site) · `mkdocs.yml` and
`docs/` (`design/`, `quirks/`, `troubleshooting.md`, `release.md`, `assets/`; also the Pages site) ·
`packaging/cask/sshdrive.rb` (the tracked cask template; the release workflow stamps its version
and sha256 into the separate tap repo `alecdwm/homebrew-tap`, of which `packaging/homebrew-tap/` is
a git-ignored checkout) · `README.md` (the user-facing one) · `testbed/` · `dist/` (git-ignored:
`release.sh` writes `SSH-Drive-<version>.dmg` there and `mac-build.sh`'s `--delete` rsync wipes it
on the VM).

## Working rules

- **This Linux box has Swift 6.3.3** (`. ~/.local/share/swiftly/env.sh`). `swift build` and
  `swift test` in `Packages/SSHDriveCore` are the ordinary loop, and the whole package builds and
  tests here: every module, every scenario, with the testbed-gated tests skipped. What the Mac runs
  and this box cannot is the handful of macOS-only assertions that check each mirrored constant and
  error code against Apple's own - the only thing that can drift silently. The seams that make it
  build: `Logging` behind a facade, the `@objc` NSXPC half in the macOS-only `XPCInterfaces` target
  that only the Apps link, `GroupContainerLocating` in `Config` (`SSHDRIVE_GROUP_CONTAINER` off
  Darwin), a `CSQLite` system-library target for `Index`, `Security` and the keychain store behind
  `#if canImport(Security)` in `Secrets`, `sysctl` and `posix_spawn` branched (with `/proc` standing
  in) in `SSHProcess`, and `AgentCore` using the mirrored `ProviderCapabilities`/
  `ProviderFileSystemFlags` rather than `import FileProvider`. When you add a `#if`, put the existing
  code in the Darwin branch byte-for-byte, and never `sed` a rename across the file that defines it.
  `cargo test` for `helper/` runs here too.
- **App bundles need the Mac VM.** `scripts/mac-build.sh` syncs the tree to
  `alec@100.114.204.5:~/sshdrive`, runs xcodegen, `swift test` and an ad-hoc signed `xcodebuild`
  (`app` or `test` argument to run one half). The VM has Xcode 26.4 on macOS 26.4, no GUI, no signing
  identities, no passwordless sudo. On Linux: edit code, then run the script.
- **The VM measures; the Linux suite proves.** A behaviour of macOS or of a server is measured on the
  VM (or on a real Mac, for anything Finder draws), written into `docs/quirks/macos.md` or
  `docs/quirks/servers.md` as a row with its version and date, taught to `SystemModel`/`ServerModel`
  as a rule keyed on that row's id, and defended by a numbered scenario. A new macOS release is a new
  column in the quirk table, not a new test. A VM session is finished when the Linux suite is green.
  What cannot be modelled at all - Finder's drawing, Gatekeeper/AMFI, LaunchServices, TCC, real
  timing, real key agents, servers we do not own - is listed in `docs/design/testing.md` and stays a
  manual check.
- **`docs/design/` is the source of truth.** When code and doc diverge, the doc wins unless the
  divergence was a deliberate decision; then change the design page that covers it, in place, so the
  page still describes one system.
- **The version comes from `VERSION`.** `scripts/set-version.sh <x.y.z>` writes it and stamps
  `project.yml`, `helper/Cargo.toml`, `Cargo.lock`, `Config/Version.swift` and the cask;
  `scripts/set-version.sh --check` names anything that disagrees and runs before every build. The
  Info.plists carry `$(MARKETING_VERSION)`/`$(CURRENT_PROJECT_VERSION)` and no literal.
  `CFBundleVersion` is the integer `major*10000 + minor*100 + patch` (0.1.4 is 104), because
  LaunchServices compares it as a number to choose between two copies of the bundle.
- **The CLI is silent by default.** A command that changes something prints nothing on success: the
  exit status is the answer. Prompts that need an answer, warnings and errors are printed whatever
  the flag says (warnings and errors on stderr). `-v`/`--verbose` restores the full report, including
  what the agent relays while the command runs. Reporting commands (`list`, `show`, `status`, `pins`,
  `doctor`, `logs`) print either way. The flag is an `@OptionGroup` per subcommand, so it is typed
  after the subcommand.
- **Delegate.** The top-level session orchestrates: it hands scoped briefs to Opus subagents for
  reading and coding, and uses Sonnet for mechanical work (renames, boilerplate, file moves, test
  scaffolding).
- **Write like the rest of the repo.** Plain, present tense, no preamble, no hype. Docs and comments
  describe what the thing does now, for someone reading it a year from now without the diff; they do
  not narrate changes, fixes or past defects. A date belongs to a measurement, never to a decision.
- **Do not run mutating git commands** (commit, push, checkout, branch, merge, rebase, reset, add, …)
  unless explicitly asked. Read-only git is fine.

## The testbed (`testbed/`)

Twelve real SSH servers: Debian and Alpine targets, every login-shell shape, an external
`sftp-server`, keyboard-interactive, `MaxSessions 2`, a busybox `find` without `-cmin`, a two-hop
`ProxyJump` chain, and a real Tailscale SSH node (`ts-ssh`: `tailscaled` serves SSH itself, so `none`
auth and a Go `pkg/sftp` subsystem). `docker compose up -d` in `testbed/`, **on the Mac that hosts
the build VM** (OrbStack), never on this Linux box. `testbed/.env` must exist first
(`cp .env.example .env`, then a Tailscale auth key): `TS_AUTHKEY` uses compose's `${VAR:?}` required
form, so without it every `docker compose` command in that directory fails, not just `ts-ssh`.

| Reaching it from the VM | |
|---|---|
| Address | `192.168.64.1` - the Mac's vmnet gateway address, ports `2201`-`2208` and `2210` |
| Reachable by | the build VM and the Mac itself. Not the LAN, not the tailnet, not this box |
| Keys | `~/.ssh/sshdrive-spike` on the VM, and `~/.ssh/sshdrive-spike-enc` (passphrase `spike-passphrase`) |
| Passwords | `spike-password`, plus `spike-password-a` / `spike-password-b` for the two bastions |
| Behind the chain | `bastion-b` and `inner` have no published port and are reachable only through `hop@192.168.64.1:2210` |
| `ts-ssh` | the exception: no port at all. It is on the **tailnet** as `sshdrive-testbed` (`alec@`, no key, no password - the tailnet ACL is the auth), which the VM reaches directly |

**Read `testbed/README.md` before using it.** The account table, the `~/.ssh/config` stanzas, the
per-service smoke tests and the traps are there: readiness is the SSH banner and not an open port, a
`-J` chain needs the jump host's key in `known_hosts` already, killing an `ssh` that used `-J` leaves
its `-W` children alive, a published port can be dead while the container is healthy, containers see
every connection as coming from the docker bridge gateway, and a re-seed needs `.testbed-seeded`
deleted.

## Docs map

Everything under `docs/design/` is one page per subject. Read the page, not the whole directory.

| Page | What a coder finds |
|---|---|
| `docs/design/goals.md` | Goals and non-goals: SFTP only, no GUI, no trash, no multi-user; the auth promise and its exceptions |
| `docs/design/platform.md` | The File Provider, OpenSSH and launchd facts every other choice rests on, each with what it forces on us; minimum macOS 14 |
| `docs/design/components.md` | The four processes, why the agent owns everything, the identifier and entitlement tables, the group-container layout |
| `docs/design/locations.md` | `config.json` field by field, and how a location reuses `~/.ssh/config` through `ssh -G` (attribution by diffing against `-F /dev/null`, the fixed override set) |
| `docs/design/secrets.md` | The askpass token protocol, the prompt classification table, keychain keying, the two-pass collect connection, touch-key refusal, the authentication deadline and its re-arm, and `known_hosts` handling |
| `docs/design/extension.md` | What the extension answers itself, the system-call to agent-action table, error mapping to `NSFileProviderError`, the XPC shape, FileHandle passing, the read-only WAL reader and the code requirement |
| `docs/design/item-index.md` | The SQLite schema, identifier rules, the content and metadata version formulas, one-transaction listings, anchors and the working set, no tombstones, backup + restore-into-live + reconcile |
| `docs/design/names-and-attributes.md` | Case and UTF-8 collisions, mode -> capabilities and `fileSystemFlags`, no trash and Finder's wording, local xattrs, Finder tags through `tagData`, `.DS_Store` |
| `docs/design/writes.md` | The temp+rename upload protocol, case-only renames, the post-upload `lstat`, the in-flight set, the conflict check and conflict copies, stale temp files, recursive delete |
| `docs/design/offline.md` | Situation -> behaviour table, the circuit breaker and its bounded waiting, the backoff as a reconnect schedule, `NWPathMonitor`, `ConnectTimeout=15`, when `disconnect(reason:)` is used |
| `docs/design/symlinks.md` | The lexical inside-the-root check under two root spellings, the relative rewrite, the `readlink` per link, what Finder draws, hidden-link collisions |
| `docs/design/ssh.md` | The exact `ssh` command lines, master and mux rules, orphan cleanup and its kill, exit classification, `ProxyJump` chain building, the login-shell env snapshot, the channel probe |
| `docs/design/sftp.md` | Wire-protocol scope, pipelining, the transfer scheduler and what the six-fetch ceiling bounds, per-request deadlines, why not a library |
| `docs/design/change-detection.md` | The three tiers and the ladder between them, scope and poll schedule, the sweep's two `find` invocations, the heartbeat wrapper, the helper's deployment and NDJSON protocol, the mass-deletion guard |
| `docs/design/root-set.md` | The `materialized`/`pinned`/`viewed` reasons, the 256 cap and the tier-0 rotation, no per-folder refresh, and where the eviction and pin timers live |
| `docs/design/eviction.md` | The 5-minute loop, what the TTL measures, TCC, the opaque eviction errors, `evict --all` and its fallback |
| `docs/design/pinning.md` | Markers versus the kept effect, the three invariants and the five-situation table for nested items, `contentPolicy`, the Finder context menu, the decoration badge |
| `docs/design/cli.md` | Every command and flag verbatim, the verbosity rule, `logs` and its two-halved predicate, and the capability report `status` prints |
| `docs/design/security.md` | The security properties, the `RelativePath` chokepoint and canonical root, and how remote commands run (`sh -s`, the sentinel, quoting) |
| `docs/design/packaging.md` | Bundle layout, CI, the cask postflight/uninstall/zap, `KeepAlive` semantics, upgrade handover, the release flow, signing and notarization credentials |
| `docs/design/testing.md` | The testing principle, the seam list, `SystemModel`/`ServerModel`, and what stays a manual check |
| `docs/design/future-work.md` | Explicitly out of v1, including the worked-out inotify tier design |

Beside them:

| Path | What it is |
|---|---|
| `docs/quirks/README.md` | The quirk catalog's rules: id format, what a row must carry, the macOS versions and servers a measurement can name |
| `docs/quirks/macos.md` | Every measured macOS behaviour (`MQ-###`), with the version and date it was measured on, the design page that acts on it and the scenarios that defend it |
| `docs/quirks/servers.md` | The same for servers (`SQ-###`); `ServerModel.ServerProfile` is built from these rows |
| `docs/troubleshooting.md` | User-facing: organised by what a `doctor` line says, and by what can look wrong when `doctor` is green |
| `docs/release.md` | The release procedure: what `release.sh` does, what Apple material it needs, what must be true first |
| `testbed/README.md` | The twelve services, accounts, `~/.ssh/config` stanzas, smoke tests and traps |
| `README.md` | The user-facing introduction |

## Things a coder gets wrong without the doc

The numbers are stable: `docs/quirks/*.md` cites them as `gotcha N`. Never renumber. A page name
in brackets is a page of `docs/design/`.

1. Transport is the system **`/usr/bin/ssh`** by absolute path with `argv[0]` set to it, plus our own SFTP v3 wire client in Swift. Not libssh2, Citadel or swift-nio-ssh; never a `PATH` lookup (`ssh.md`, `sftp.md`).
2. The master is `ssh -N` with `ControlPersist=no` - with it set, `ssh` forks away and the agent loses the pid, stderr and exit signal. `ControlPath` is `$TMPDIR/sshdrive-<id8>`, never `%C` (collides for two locations on one host; 104-byte socket limit) (`ssh.md`).
3. Mux clients run `-F /dev/null -o BatchMode=yes -o ProxyCommand=/usr/bin/false`; otherwise a missing socket makes `ssh` open a *second, unsupervised* connection instead of failing. A mux client exiting before its channel opened is always "master lost", never an auth failure (`ssh.md`).
4. `ProxyJump` is never handed to `ssh`: cancel it with `ProxyJump=none` and rebuild each hop as the agent's own `ProxyCommand` with the same overrides plus `ControlMaster=no` **and `ControlPath=none`** (`no` alone still attaches to the config's socket). Write the `ProxyCommand` **first** and the cancellation after it, and double a nested hop's `%h`/`%p` once per level (`ssh.md`, gotcha 33).
5. A location that passed the collect connection's first pass runs `IdentityAgent=none` for good; only `agentDependent` locations ever consult a key agent (`secrets.md`, `ssh.md`).
6. askpass holds nothing: it sends the agent a one-time `SSHDRIVE_ASKPASS_TOKEN`, the prompt, `SSH_ASKPASS_PROMPT` and its parent `ssh`'s argv (`sysctl KERN_PROCARGS2`). Keychain items are keyed `password:<user>@<hostname>:<port>` / `passphrase:<keypath>` from `ssh -G`, never the alias, shared across locations. The **host-key question arrives with `SSH_ASKPASS_PROMPT` unset**, exactly like a password prompt, so it is classified by its own text and the hint is only corroboration; `Enter passphrase for key '%.100s'` truncates, so the prompt text alone can never be the key. The three variable names live once, in `XPCProtocols/AskpassEnvironment.swift` (`secrets.md`).
7. Authentication has a **60 s deadline from spawn**, signalled by the control socket appearing; the 15 s `ConnectTimeout` is contained in it, never added. A deadline stop is re-armed for exactly one attempt on screen unlock or a request arriving with input idle < 30 s and the screen unlocked; refusals are never re-armed (`secrets.md`, `offline.md`).
8. Every remote path goes through the **`RelativePath` chokepoint** - the SFTP layer exposes no string-path API. Zero components is the root. System filenames, CLI paths, sweep output and helper events all pass the same constructor (`security.md`).
9. **No tombstones.** A deleted row goes with its pin marker and xattrs; a re-created path is a new item with a new identifier (`item-index.md`).
10. `content_version` is `"\(size)-\(mtime)-\(generation)"` at **every tier** with whole-second mtime, so a tier change is invisible. ns-mtime and inode are separate columns, feed change detection only, and are **reset to null after every upload of ours** (`item-index.md`, `writes.md`).
11. The extension opens `index.sqlite` read-only in WAL mode for `item(for:)` and the working set; the agent is sole writer. A reader that is not ready, any SQLite error there, or `meta.reconciling` hands the call to the agent, which answers from its own connection or, while reconciling, refuses with `.serverUnreachable`; **never `.noSuchItem`** - that deletes the user's file (`extension.md`, `item-index.md`).
12. A row is a finished item: `capabilities`, `fs_flags`, `kept` and `link_target` are derived and stored by the agent. The extension never re-derives them and never walks ancestors (`extension.md`).
13. Every exec channel runs exactly `sh -s` with the script on stdin, values single-quoted through `set --`. Each script prints a random 128-bit sentinel first and the agent discards everything before it, because rc files print on non-interactive startup (`security.md`).
14. Nothing on the server runs bare: the wrapper backgrounds its child with `< /dev/null`, reads a 15 s heartbeat, and kills the child after 60 s of silence or EOF (`change-detection.md`).
15. Sweep windows come from the **server's** clock (`date +%s` printed by the script, stored only after results are applied) and use `-cmin`, with a `-mmin` fallback on **every** busybox - no busybox build has `-cmin`, so that fallback and its `status` note are the ordinary NAS path, not a legacy case (`change-detection.md`).
16. The mass-deletion guard holds listing-derived deletions removing >= half a directory and >= 20 items (or emptying a non-empty root), re-checking at 5 and 30 min. Helper delete events apply at once. A fetch of a held item fails `.cannotSynchronize`, never `.noSuchItem` (`change-detection.md`).
17. Uploads go to `.sshdrive-upload-<mac8>-<uuid>` then non-overwriting `rename` (create) or `posix-rename@openssh.com` (overwrite), then `setstat` the mode back, then `lstat` for the version. Never write in place (`writes.md`).
18. A path with an upload in flight sits in the **in-flight set** and change detection skips it; otherwise our own writes come back as remote changes (`writes.md`).
19. The conflict check compares size and mtime from a fresh `lstat` **and** `generation` from the row - the wire cannot carry generation, and without it a same-size same-second remote change is overwritten (`writes.md`).
20. `allowsTrashing` is never set (no trash); xattrs and Finder tags stay local and hash into the metadata version; `.DS_Store` is swallowed as a local-only row with its bytes in `local_content` (`names-and-attributes.md`).
21. Symlinks are native items, **never followed**, shown only if a lexical check keeps them inside the root under either spelling (canonical `realpath` or user-typed/`$HOME`); absolute in-root targets are rewritten relative for the Mac; failures are omitted from enumeration entirely (`symlinks.md`).
22. Pin markers (`pin_state`) live in the index, the sole authority. **Any change to a path's explicit state first deletes every explicit state beneath it**, silently from Finder too, and a pin change rewrites and anchors **every known descendant row** (`pinning.md`).
23. What stops a kept item being evicted is its **eager `contentPolicy`**, inherited by the system; `allowsEvicting` is deprecated since macOS 13 and dropping it changes nothing - the system reports the bit from `isDownloaded`, not from us (measured on macOS 26.4, 2026-09-04). An eviction that reaches a kept item anyway is **re-asserted**, not read as an unpin (`pinning.md`).
24. The SFTP wire gives status classes, not errno: `ENOSPC`, `EEXIST`, `ENOTEMPTY`, `EXDEV` all arrive as bare `FAILURE` - ask a second question (`lstat`, `statvfs`, `readdir`). Also OpenSSH's `SSH2_FXP_SYMLINK` takes its two paths in the **opposite order from the draft** (`sftp.md`).
25. A pin on a path nothing has ever listed is not done when the rows are reported: the system ingests nothing from the working set alone, so `pin` finishes with `getUserVisibleURL` + one `lstat` of the replica, which is what makes it enumerate the chain (`pinning.md`).
26. Finder tags never arrive as an xattr: they are the item's `tagData`, and the system wipes them on the next re-download if the item does not return them. It also only reports xattrs it considers syncable (`names-and-attributes.md`).
27. A corrupt index is restored **into** the live database via `sqlite3_backup_init` (never by replacing the file: the `-wal`/`-shm` sidecars and the extension's open reader belong to the old inode), then reconciled against the replica under `meta.reconciling` (`item-index.md`).
28. The domain's `displayName` is the **bare nickname**: the system prepends the app name to the mount directory and to the sidebar label itself (`platform.md`, `locations.md`). `add(domain)` with the same identifier and a new `displayName` renames in place, keeping the mount directory's contents, the materialized set and a pending upload, which is what `set nickname` does.
29. **A folder is enumerated once, ever.** Revisiting it in Finder, or a remote change landing while it is open, produces no container-enumerator call at all; everything after the first listing arrives through the working set (`root-set.md`).
30. The system **believes whatever version a `modifyItem` reply carries** - it never re-fetches and never re-offers - so a conflict copy must `evictItem` the item after returning the remote one, and `.filenameCollision` from `createItem` is retried for ever with no alert (`writes.md`).
31. A custom action's activation rule binds **`fileproviderItems`** (lower-case p) as a **key path**, not a `$` substitution variable. Either mistake drops the menu entry silently; `fileproviderctl evaluate <path>` is how to check (`pinning.md`).
32. Finder contributes exactly two File Provider entries, **"Download Now"** or **"Remove Download"** by `isDownloaded`, and draws no built-in "Keep Downloaded" for us. Our two actions land **at the bottom of the contextual menu, top level**, and on the window background, but **never on the sidebar row** - so a whole location is pinned only from the CLI (`pinning.md`).
33. **`-o ProxyCommand=…` is written before `-o ProxyJump=none`.** Both keywords write the same field and `ssh` takes the first, so the reverse order makes OpenSSH discard the `ProxyCommand` outright and the master then resolves a hostname that only exists behind the bastion. A nested hop's `%h`/`%p` are doubled once per level it sits below the master (`%%h:%%p` at hop *n-1*), because `ssh` percent-expands the whole string before `/bin/sh -c` sees it; without that, hop 1 dials the destination. A `ProxyJump` in a location's own `sshOptions` reaches `ssh -G`, where the chain builder wants it, and is stripped from the master's command line (`ssh.md`).
34. **Every sentinel's NUL is printed by a `printf` of its own.** `printf "\0<sentinel>"` reads `\0` and the octal digits after it as one character, so a sentinel beginning with a digit silently loses its first bytes and the marker is never found (`ssh.md`, `security.md`).
35. **Every `sh -s` script is one `{ … }` group ending in an `exit`.** A compound command must be parsed whole before any of it runs, which is what stops the heartbeat reader eating the script's own tail off the same stdin - and `.` with no argument is a POSIX special builtin that ends a non-interactive shell outright (`security.md`).
36. **The heartbeat wrapper reads heartbeats from a descriptor duplicated in the parent, and every subshell clears the `EXIT` trap;** without either it kills its own healthy child seconds after starting it. Its stamp file is `touch`ed, never `:`-redirected, and the `sleep`-and-mtime branch is the *ordinary* Linux path, because an exec channel runs `sh` and Debian's `sh` is dash (`change-detection.md`).
37. **A `ForceCommand internal-sftp` account may answer an exec channel with a plain sentence,** `This service allows sftp connections only.`, rather than SFTP framing. The probe recognises both and reports "no shell access (ForceCommand)", never "shell output unusable" (`security.md`).
38. **`limits@openssh.com` sizes the request, not the window.** It says nothing about how many requests may be outstanding, so the chunk size is the server's and the depth of sixteen is ours (`sftp.md`).
39. **An SFTP channel is a mux client of the master** (`ssh $MUX -s <host> sftp`), and the wire client sits on the same `ByteStream` an exec channel hands over - one definition, in `SSHProcess`, which `SFTP` depends on. `SFTPSubprocess`, which spawns an `ssh` of its own, is a test path only (`ssh.md`, `sftp.md`).
40. **stderr distinguishes no key-agent state.** A missing socket, a dead socket and a *locked* agent all exit with the same bare `Permission denied (publickey)` at `LogLevel=ERROR`, so the pre-spawn socket probe is the only signal; `agent refused operation` corroborates, it does not decide (measured 2026-09-04) (`ssh.md`).
41. **SFTP `opendir` follows a symlink,** so every listing re-`lstat`s its own directory before `readdir`: a directory swapped on the server for a link to `/etc` is otherwise read straight through and every name under it gets a row (measured 2026-09-04) (`security.md`).
42. **The six-fetch ceiling bounds an eager subtree, not the queue.** Eight files opened at once from a shell arrive as eight simultaneous foreground `fetchContents` calls, so a transfer past the ceiling is admitted and counted, never refused (`sftp.md`).
43. **A directory listing is written in one transaction.** Row by row, a 10,000-entry directory is 10,000 autocommits and `ls` of the mount answers `fts_read: Operation timed out` (`item-index.md`).
44. **The `MaxSessions` probe asks "may I hold three channels at once",** not "what is `MaxSessions`", and proves a channel open by completing the SFTP handshake on it: `ssh` spawns successfully whether or not the session was granted. The answer is cached per location, because the agent never sees a server banner to key it on (`ssh.md`).
45. **The index's transaction helper nests.** "A listing is one transaction" wraps calls that are each a transaction of their own (`appendAnchor`, `delete`), and SQLite has no nested `BEGIN`: below the outermost level it is a `SAVEPOINT` (`item-index.md`).
46. **The collect connection of `add` runs to 300 s, not 60.** The deadline exists because nothing may wait for a human unattended; a person *is* at the keyboard for that one connection. The master `add` brings up afterwards carries the 60 s (`secrets.md`).
47. **The CLI exports an object.** The agent relays the collect connection's prompts back along the same connection, so the listener hands a `sshdrive` peer the CLI callback interface and everyone else the extension's - the same rule that gives askpass its own (`secrets.md`, `extension.md`).
48. **The CLI's stdout is unbuffered.** The agent writes relayed prompts through the file descriptor; a buffered `print` from the CLI's own report would land out of order behind them whenever stdout is a pipe (`cli.md`).
49. **The conflict copy's eviction has to be retried and the working set signalled.** An `evictItem` straight after the `modifyItem` reply is refused `NSFileProviderErrorNonEvictable` (-2008) - the system is still finishing the modification - so it retries with a doubling backoff from 0.25 s; and the copy is a new sibling in a folder that will never be enumerated again, so its anchor needs a working-set signal or Finder never shows it (measured on macOS 26.4, 2026-09-04) (`writes.md`, `root-set.md`).
50. **The xattr hash does not prevent a retry loop, because there is none.** A tag change is not re-offered even when the reply carries the version the item already had. The hash is what makes a change the **agent** makes reach the system - a restore from the index backup - and nothing else (measured on macOS 26.4, 2026-09-04) (`names-and-attributes.md`, `item-index.md`).
51. **Finder tags are an `NSKeyedArchiver` archive in `tagData`,** never an xattr: `changedFields` carries `NSFileProviderItemTagData` (`0x10`) with an empty `extendedAttributes`. Stored and served opaquely, never parsed (measured on macOS 26.4, 2026-09-04) (`names-and-attributes.md`).
52. **A `.DS_Store` written into the mount never reaches the extension.** The system keeps it in the replica and never asks anyone to upload it, so the local-only path exists for other writers, not for Finder (measured on macOS 26.4, 2026-09-04) (`names-and-attributes.md`).
53. **A local-only row survives a listing that does not mention it** - the one exception to "deleted rows are deleted", and without it the first listing after the create takes the user's file (`item-index.md`, `names-and-attributes.md`).
54. **Every symlink a listing reports costs a `readlink`:** SFTP v3's `readdir` carries attributes but no target. Finder then draws the link as Kind **"Alias"** with the arrow badge, dangling or not, with no broken-link marker (measured on macOS 26.4, 2026-09-04) (`symlinks.md`, `sftp.md`).
55. **A refused `ln -s` is a sync error, not a message.** The create succeeds locally and the refusal comes back as the item's `uploadingError` with the system's own wording, so the design's sentence only reaches the user through `sshdrive status` (measured on macOS 26.4, 2026-09-04) (`symlinks.md`).
56. **`launchctl kill` plus `open -g` does not reinstall the agent** - launchd brings the old binary back before `ditto` finishes and `open -g` then does nothing. Use `sshdrive agent restart`, and check `ping`'s `interfaceVersion`. Related: `pgrep` lists killed mux clients as zombies until the agent reaps them, and a restarted location can hold two masters.
57. **macOS asks for Local Network access in the app's name on first connect,** which every NAS on the user's own network will hit; no entitlement suppresses it and a launchd agent has no window to put it over (`platform.md`, `packaging.md`).
58. **`signalErrorResolved(.serverUnreachable)` is the only thing that flushes a queued write.** `signalEnumerator` alone does not, and neither does reconnecting; the queued `modifyItem` arrived 20 ms after the signal and not at all without it (measured on macOS 26.4, 2026-09-04) (`offline.md`).
59. **The system re-offers a queued write on a doubling backoff past five minutes, and re-issues a failed `fetchContents` never.** So the agent reconnects on the breaker's backoff **unprompted**, and a read that meets a silently dead connection is retried once through the breaker; a write is not (its source cannot be replayed, and the write is the one thing the system does re-offer) (measured on macOS 26.4, 2026-09-04) (`offline.md`).
60. **The system does not time out an `enumerateItems` held the full 60 s** the breaker may hold a call for, and leaves the extension running. Finder draws a static circular progress ring in place of the dataless badge for the length of the wait, with no alert (measured on macOS 26.4, 2026-09-04) (`offline.md`).
61. **`disconnect(reason:)` works from inside the extension.** With the login item unregistered the domain goes `permanently disconnected` (state 4); the replica listing and queued writes survive, and re-launching the app lifts it and flushes them (measured on macOS 26.4, 2026-09-04) (`offline.md`, `extension.md`).
62. **From `fetchContents`, `.noSuchItem` and `.cannotSynchronize` both leave the item in place** - `ESTALE` against `ETIMEDOUT`. The "never `.noSuchItem`" rule is about `item(for:)` and only about it (measured on macOS 26.4, 2026-09-04) (`change-detection.md`, `extension.md`).
63. **A pending edit on an item reported deleted comes back as a `createItem`,** which collides with the path still on the server and is then retried for ever with no alert - the save is stranded and the identifier is new. The mass-deletion guard must hold deletions of pending items (measured on macOS 26.4, 2026-09-04) (`change-detection.md`, `writes.md`).
64. **Sleep and wake are IOKit, and the constants do not import.** `kIOMessageSystemWillSleep` and friends are `iokit_common_msg()` macros, spelled out as `0xE0000280` / `0xE0000270` / `0xE0000300`; `CGEventType` likewise has no `.any`, so the presence read is `CGEventType(rawValue: ~0)`. The will-sleep message must be acknowledged with `IOAllowPowerChange` (`ssh.md`).
65. **`launchctl setenv` does not reach a launchd agent on macOS 26,** even across `sshdrive agent restart`, so an override for the agent is a file in the group container (measured on macOS 26.4, 2026-09-04) (`secrets.md`).
66. **`scripts/mac-build.sh` rsyncs with `--delete` and there is no `build/` on the Linux side,** so every run wipes the Mac's build directory. Run `signed` last, or `ditto` fails with "Cannot get the real path for source".
67. **The local-attributes blob is encoded with `JSONEncoder` and `.sortedKeys` is load-bearing.** The blob is hashed into the metadata version, and without a sorted key order the same attributes encode to two different byte strings *within one process*, the hash moves, and the system re-reads every item the agent holds (`item-index.md`, `names-and-attributes.md`).
68. **The build VM does not honour `pmset sleepnow`** (`error 0xe00002e2`, exit 71): `powerd` holds "Prevent sleep while display is on". `IORegisterForSystemPower` does register there, so the handlers are driven with `sshdrive debug power will-sleep|did-wake` and only the delivery is unproven (measured on macOS 26.4, 2026-09-04) (`ssh.md`).
69. **A bare background process on the server survives an abrupt client kill whatever `ClientAliveInterval` is set to.** sshd reaping the session does not reach a child that has left the foreground job: measured alive three minutes later on Debian with it unset, Debian with it at 15/3, and Alpine/busybox with it unset (2026-09-04). The heartbeat wrapper is the only thing that ever kills what we started (`change-detection.md`).
70. **`-cmin` and `-printf` each cost a `stat` per entry, and that is what a sweep spends.** Over a million files, warm: 204 ms with `-print0` and no time test, 850-900 ms adding `-cmin`, 1.6-3.0 s adding `-printf` (measured 2026-09-04). The ordinary incremental sweep of that tree is under a second and returns one record (`change-detection.md`).
71. **Every sweep root is spelled `./name`.** `find` has no portable `--`, so a top-level directory named `-name` would be read as an option and take the whole sweep with it; the prefix comes back on every path and is stripped before the `RelativePath` constructor (`change-detection.md`).
72. **A sweep root whose bytes are not valid UTF-8 never reaches `find`** - `set --` is a String pipeline end to end - so it is dropped from the argv and listed at tier 0 in the same cycle instead (`change-detection.md`, `security.md`).
73. **busybox `find --version` prints an error and exits 0,** so the flavour probe reads the `busybox` banner and the `-cmin` answer, never the exit status. And `SweepPlan` refuses `-cmin`/`-printf` on a busybox flavour even when the probe claims them: a busybox `-cmin` does not lose a field, it fails the whole sweep (measured on BusyBox 1.36.1 / Alpine 3.20, 2026-09-04) (`cli.md`, `change-detection.md`).
74. **The sweep's server timestamp is stored only after its results are applied, and a truncated sweep stores nothing,** so the next window still covers what the cut-off one missed (`change-detection.md`).
75. **A directory rename rewrites `held.dir` as well as `held.path`,** or the guard's 5- and 30-minute re-checks re-list a name that no longer exists and the holds never resolve (`item-index.md`, `change-detection.md`).
76. **The reconcile walk runs after `add(domain)`, never inside `start()`** - it reads the system's replica - so the restore leaves `meta.reconciling` set and the walk is what clears it. A walk that hits its deadline or item cap **still clears the flag**, because the alternative is a domain stalled for ever (`item-index.md`).
77. **A CLI command naming a location is a touch,** and it has to be: a folder is enumerated once ever, so a user watching a mount from a terminal produces no File Provider traffic at all and the location would sit at the ten-minute cadence while they worked (`change-detection.md`, `root-set.md`).
78. **The working set asks the agent while its reader is not ready, and never answers an empty change set.** `.serverUnreachable` is kept for an agent that cannot be reached: fileproviderd throttles a change enumeration that keeps returning it. The system launches a fresh extension instance for every working-set signal, so the first `enumerateChanges` on a signalled instance races the `indexReady` round trip; "no changes" at the anchor the system already holds tells it that it is up to date and the change is dropped until something else signals - a deleted file then sits in Finder indefinitely though it is gone from both the server and the index (measured on macOS 26.4, 2026-09-04) (`item-index.md`, `extension.md`).
79. **The orphan control-socket sweep matches on the socket type, not the name.** `$TMPDIR` is shared and `sshdrive-` is not ours exclusively there - the package's own test databases are `sshdrive-nested-<uuid>.sqlite`, and their `-wal`/`-shm` sidecars made `sshdrive doctor` report a clean install as failing, with six "orphaned sockets" it would have deleted. Each candidate is `lstat`ed and only `S_IFSOCK` counts (`ssh.md`).
80. **atime is not in the TTL's `max`.** Something in the system advances a materialized file's atime minutes after the fetch, deferred and with no read of ours near it, so with atime in the rule the TTL silently becomes "time since whatever last touched the replica" - a file fetched 280 s earlier survived a 60 s TTL. It is read, logged beside the age the decision used, and decided on by nobody; `last_fetch` and the later of the replica's and the row's mtime are the whole rule (measured on macOS 26.4, 2026-09-05) (`eviction.md`).
81. **A decoration's Info.plist keys are the bare `Identifier`, `BadgeImageType`, `Label` and `Category`,** not `NSFileProviderDecoration`-prefixed spellings and not the `NSExtensionFileProviderAction*` shape beside them, and `BadgeImageType` is a **UTI conforming to `com.apple.icon-decoration.badge`** (the system ships `.badge.pinned`), never an asset name. Every mistake is silent, like `fileproviderItems`. Finder draws a `Badge` at the trailing edge of the Name column, not on the icon (measured on macOS 26.4, 2026-09-05) (`pinning.md`).
82. **`evict --all` is one call on the root container only while nothing is *or has just been* pinned.** With a pin in place it meets a kept child and fails as a whole, and straight after `--unpin-all` it fails as `NSCocoaErrorDomain` "The file couldn't be opened" because the system has not re-read the rows whose policy just changed - a single file becomes evictable 5-10 s after an unpin, the container did not within a minute. Both cases fall back to walking the materialized set with the write path's backoff per file, which leaves the directory rows materialized (measured on macOS 26.4, 2026-09-05) (`eviction.md`, `pinning.md`).
83. **A pin change rewrites the changed row *and every known descendant row*,** because `contentPolicy` is inherited by the system but `userInfo.kept`, the badge and the capabilities are per item and cached until that item's own metadata version moves. Invariant 2 clears every explicit state beneath first, which is what makes the rewrite one value rather than a per-row ancestor walk (`pinning.md`).
84. **The helper cannot be started `< /dev/null` *and* fed on its stdin.** Every background child starts with no stdin so it cannot swallow the heartbeat lines, but the helper is fed its root set and its pings on stdin. Only one process may read a pipe, so the wrapper stays the only reader and **relays** each line into a FIFO the helper is given instead (`RemoteScript.stdinRelay`). A server where `mkfifo` fails runs it `< /dev/null` with its roots on its argv. And the relay fragment already ends in a `;`: writing `… || break; <relay>; done` makes `;;`, which dash answers with `Syntax error` and the channel dies at once (`change-detection.md`, `security.md`).
85. **A hash the build embeds in a binary is not the hash of that binary.** `--version` prints the SHA-256 the helper computes of **its own executable** at startup, which is what makes the "size plus `--version`" fallback the same check as the `sha256sum` path rather than a weaker one (`change-detection.md`, `security.md`).
86. **Tier 2 needs an exec channel it can *hold*, not merely open.** A sweep spends half a second on one and gives it back; the helper's stream keeps one for the life of the connection. At `MaxSessions 2` the single spare channel is shared with the probe and the 30-minute insurance sweep, so the helper is refused there - `ChannelBudget.allowsPersistentExecChannel` (`ssh.md`, `change-detection.md`).
87. **The helper's `ready` line is what the ladder settles on.** "The first tier that starts successfully" cannot be decided from the channel opening: `sh` may print anything. `ready` (and `error`) are part of the NDJSON protocol, and a non-UTF-8 path travels as `path_b64` because a JSON string is UTF-8 by definition (`change-detection.md`).
88. **The helper's deployment is the one exception to the `RelativePath` chokepoint.** It writes to `~/.cache/sshdrive`, outside every location root by design, so `SFTP` exposes `HelperDirectory`/`HelperFile` - a probe-chosen absolute directory plus one filename component, no `..`, no nesting - and nothing on the File Provider path can build one (`security.md`, `change-detection.md`).
89. **Writing over a running helper fails `ETXTBSY`,** which is why the upload goes to a temp name and renames; and **the wrapper's `EXIT` trap does not run when the wrapper is `SIGKILL`ed**, which is every abrupt client kill, so its relay FIFO is swept by the next deployment instead (`change-detection.md`, `writes.md`).
90. **`aarch64-unknown-freebsd` has no prebuilt `rust-std`** - `rustup target add` refuses it - so it cannot be built or even `cargo check`ed, and the helper's FreeBSD target is x86_64 only. The three musl targets need no `cross` and no C toolchain: `rust-lld` with `-C link-self-contained=yes` (`packaging.md`).
91. **A provisioning profile only authorises the certificate it was issued for.** A profile carries its `DeveloperCertificates`, and AMFI matches on them: one created against a *different* Developer ID Application certificate than the signing one makes **every** restricted entitlement unsatisfied (`taskgated-helper: Unsatisfied entitlements: keychain-access-groups`, `amfid: -413 "No matching profile found"`), and the agent is SIGKILLed at exec with a `Launch Constraint Violation` - `open -g` says `Launchd job spawn failed`. It signs, verifies, **notarizes and staples** first: notarization never looks at profiles. Adding `com.apple.application-identifier` to "match properly" makes it worse and is a private-entitlement dead end anyway. `scripts/release.sh` compares the hashes before signing and drops the entitlement rather than ship a bundle that cannot launch (`packaging.md`, `components.md`).
92. **`xcrun notarytool store-credentials` cannot run over ssh** - "User interaction is not allowed", with the login keychain unlocked - so a headless release notarizes with an App Store Connect API key (`--key`, `--key-id`, `--issuer`). A read-only key notarizes fine but **cannot create a provisioning profile** (`403 FORBIDDEN_ERROR`) (`packaging.md`).
93. **`SMAppService.unregister()` returns before launchd has dropped the job, and the job being gone is still not enough.** `status` says `notRegistered` while launchd is spawning the old record, and a `register()` inside that window leaves the job carrying the previous bundle's launch constraint: every spawn dies `EXC_CRASH (SIGKILL (Code Signature Invalid))` with `Launch Constraint Violation` on a 10 s retry, for ever, while the mach service accepts connections and answers no command. The `unregister` role polls `launchctl print` until the service is gone **and then waits a 5 s grace**, because the poll can answer gone 7 ms after `unregister()` returns and a register 110 ms later is constrained anyway; 5 s worked first time on the same bundle. The launch also verifies: `AgentLifecycle.registerAndVerify` registers, pings the agent for up to 10 s, and on silence unregisters, waits, and registers again, up to three times; a register made 100 ms after the grace still died on 26.4.1 and the second repair started the agent. A build signed with a different certificate from the installed one is what exposes this - the constraint comes from the signature (measured on macOS 26.4, 2026-09-05, and 26.4.1, 2026-09-23, installing 0.1.5 over 0.1.4) (`packaging.md`).
94. **The agent handles SIGTERM itself.** Death by signal is an unsuccessful exit, `KeepAlive` with `SuccessfulExit` false restarts at once, and mid-upgrade that is the old bundle. TERM runs the same shutdown as `agent stop` and exits 0, which is what makes the cask's `signal:` stanza safe (`packaging.md`).
95. **`add(domain)` can report `NSCocoaErrorDomain 4099` ("connection to com.apple.FileProvider was invalidated") after the call has landed.** Seen on `set nickname` and on the first location start after an upgrade. The domain list is the authority: `addDomain` re-reads `NSFileProviderManager.domains()` before believing the error (measured on macOS 26.4, 2026-09-05) (`extension.md`, `packaging.md`).
96. **`sshdrive logs` reads fileproviderd's lines too.** Everything the *system* decides about a domain is under Apple's subsystem and never reaches ours, and `--info` must be passed or `log show` hides most of the transport. `/usr/bin/log` is spelled absolutely: zsh has a `log` builtin (`cli.md`).
97. **A pending upload survives a bundle replacement and can be re-offered after it,** so the same write can arrive twice; the conflict check is what makes that safe, and it produces a conflict copy rather than a loss (measured on macOS 26.4, 2026-09-05) (`packaging.md`, `writes.md`).
98. **A zsh harness must spell `${=K}`.** zsh does not word-split an unquoted parameter, so `ssh $K …` with `K="-o BatchMode=yes -i key"` passes it as one argument and every remote command fails with `keyword batchmode extra arguments at end of line`. A latency run then "passes" the steps that check for absence, because a file that was never created is also never seen.
99. **LaunchServices registers no plugin of a quarantined bundle nobody has launched.** Homebrew leaves `com.apple.quarantine` on the installed app, `open -g` is not an assessed launch, and the appex then does not exist: `pluginkit -m` prints nothing, `doctor` fails "extension registered" and "file provider domains" ("The application cannot be used right now"), and `fileproviderd` logs `getDomainsForProviderIdentifier((null)) failed: FP -2001 Underlying FP -2014`. The agent is unaffected - launchd starts it directly - so the install looks finished. `pluginkit -a` registers it and the next launch wipes that again; `xattr -dr com.apple.quarantine` then `open -g` is durable. The cask's postflight runs `spctl --assess` and then the strip before its unregister and open, and `doctor` has a `quarantine` check ahead of "extension registered" (measured on macOS 26.6.2, 2026-09-05; a quarantined install by a fresh user on macOS 26.4.1 had passed, and which half of that difference matters is not claimed) (`packaging.md`).
100. **A `kill … 0` in a remote script is only safe where sshd gave the session its own process group.** Tailscale SSH runs every session in `tailscaled`'s process group, shared with every other session of every client, so a heartbeat wrapper's `kill -TERM 0` kills the account's other sessions **and the connection under them**: the helper's exec channel exits 255 and the tier-1 sweep drops the master once a cycle. The wrapper names `-$$` - the group *this shell leads*, which is the same group where sshd gave us one and a harmless `ESRCH` where it did not - and signals the child by pid on both passes so the helper still cannot outlive the connection. Read the pgid with `/proc/$$/stat` if you ever need to see it; on that node it is `tailscaled`'s pid (measured 2026-09-08) (`change-detection.md`).
101. **The one `ssh` that can read the server's identification string is the collect connection.** Masters run at `LogLevel=ERROR` and mux clients never speak to the server, so `add`'s verification connection runs at `DEBUG1`, `remote software version …` is taken out of its stderr into `capabilities.json`, and the `debug1:` lines are stripped before the exit classifier or `add`'s message sees them. Beside it the SFTP extension fingerprint is free on every connection: exactly `hardlink`, `posix-rename` and `statvfs` is Go `pkg/sftp`; anything with `fsync`/`lsetstat`/`limits` is OpenSSH's own `sftp-server`. `status` names the server, and "not OpenSSH" and "not identified" stay different answers (`cli.md`, `ssh.md`).
102. **`ssh` ends every stderr log line with CRLF, and in Swift `"\r\n"` is one `Character`,** so `split(separator: "\n")` finds no separator in `ssh -v` output at all: the whole transcript is one "line" and the first value read off it takes the rest of the file with it. Normalise line endings on **unicode scalars** before splitting (`cli.md`).
103. **The helper's stream is per connection, so re-opening it belongs to the reconnect, not to the next poll cycle.** A master that died, an agent restart, a wake or a network path change otherwise costs up to 60 s of no push detection on a touched location, up to 10 minutes on an idle one, and for ever on a location a runtime failure had dropped. `ReconnectSequence` in `AgentCore` owns the order and `DomainManager` drives it: `applyConnection`, `applyCapabilities`, `reopenHelperStream`, `signalErrorResolved`, `signalWorkingSet`. The stream comes **after** the SFTP channels because both are channels of the master that step rebuilt, and it is started on the detector's own actor rather than awaited, because `DomainManager` is where every File Provider request serialises (`change-detection.md`, `offline.md`).
104. **A tier failure is permanent only for the reasons the design lists as permanent.** The helper's stream dies with **every** connection, so treating that as permanent turns a 90-second stall into a mount stuck at sweep until the agent is restarted. Permanent is: no shell, no exec channel, an unsupported OS or arch, a `noexec` directory, a hash that came back and disagreed after a redeploy, a `find` that is missing. Everything else holds the tier for 2 s doubling to 60 s and then climbs back; a connection coming up clears the hold and the backoff outright. And the loop has to be woken for it: a 2 s hold recorded while the detector is asleep for the rest of its minute measures as a 21 s climb back (`change-detection.md`).
105. **"helper upload failed" is two different failures.** `HelperDeployment.verdict` answers "the copy on the server does not match this build" when a hash came back and disagreed - about the file, permanent - and "the server could not verify the helper's contents" when the size matched and **nothing** could vouch for it, which is what an exec channel that will not run `sha256sum` or `--version` produces. Reading the second as permanent parks a location at sweep for the session against a server that is fine a minute later. `HelperDeployment.uploadFailureIsPermanent(after:)` is the split (`change-detection.md`).
106. **A channel that did not open says nothing about `MaxSessions` unless the master is alive.** `ssh` fails a channel open just as readily because the master has gone (`Control socket connect: No such file or directory`, `mux_client_hello_exchange: … Broken pipe`, or nothing at all), and a cached budget with no invalidation makes one connect attempt in a bad moment a permanent "MaxSessions 1", taking the exec channel, the identity, the sweep and the helper with it across every later restart. `ChannelProbeVerdict` classifies (a real refusal on a live master is still a refusal, and so is unfamiliar wording on a live master), a probe that met a dying connection **records nothing** and fails the connect attempt instead, and an abrupt loss of a connection that was up marks the cached budget suspect so the next connect re-probes (`ssh.md`, `cli.md`).
107. **LaunchServices keys its records on the bundle identifier, and a record for a second copy of the app answers every registration of the installed one.** Opening the app once from the mounted DMG leaves a record for `/Volumes/SSH Drive/SSH Drive.app`, and detaching the volume does not remove it. While it is there, `lsd` answers every registration of `/Applications/SSH Drive.app` - the cask's own `lsregister -f -R -trusted` included - with `SecStaticCodeCreateWithPath(<private>) failed with error -67028`, `skipping registration of an incomplete bundle` and `Registration succeeded, but did not actually register anything new; returning existing bundle`, so `pluginkit -m` prints nothing, `doctor` fails "extension registered" and "file provider domains", and no domain can be added, on a bundle with no quarantine attribute at all. `lsregister -u` on the stale path and then the force registers the appex at once. The cask's postflight and the app launch both sweep before they force, and `doctor` lists every record path that is not the installed bundle (measured on macOS 27.0, 2026-09-23, upgrading 0.1.7 to 0.1.8 with a three-hour-old DMG record; 26.4.1 produces no `/Volumes` record from the same upgrade) (`packaging.md`).

## Glossary

- **root set** - the bounded directory set every tier watches: `materialized` + `pinned` (recursive) + `viewed` (least recently enumerated evicted past 256; cleared when the agent restarts). Nothing else is polled (`root-set.md`).
- **working set** - the File Provider change stream. Only ever a change stream, never a listing; `enumerateItems` on it returns nothing (`item-index.md`).
- **anchor** - an `anchors` row (sequence number + changed identifier + kind) replayed by the working-set enumerator; expiry answers `.syncAnchorExpired` and triggers a full sweep (`item-index.md`).
- **reconcile** - rebuilding the index from the system's replica by walking the mount and calling `getIdentifierForUserVisibleFile(at:)`, under `meta.reconciling`, which stalls all service (`item-index.md`).
- **pin / excluded / kept** - `pinned`/`excluded` are markers on a path; **kept** is the effect at an item (nearest marker at or above it is a pin). Kept is what everything acts on (`pinning.md`).
- **tier 0 / 1 / 2** - poll (SFTP `readdir`) / sweep (`find` over exec) / helper (our Rust binary, push ~1 s, real renames). `watchMode: auto` tries top down and degrades (`change-detection.md`). Tier 2 latency measured at 76-903 ms against tier 1's 60 s.
- **helper** - `sshdrive-helper`, the Rust crate in `helper/`. Uploaded to `~/.cache/sshdrive` over SFTP, hash-verified against `Contents/Resources/helper/manifest.json`, run on one held exec channel under the heartbeat wrapper, and speaking NDJSON back. `helper on|off` per location; `HelperDeployer` puts it there, `HelperStream` reads it (`change-detection.md`).
- **sweep** - one exec-channel `find` pass over the root set within a window from the **server's** clock; also the 30-min insurance pass. **full sweep** = window opened to the last recorded server timestamp, run on reconnect and on fresh anchors (`change-detection.md`, `item-index.md`).
- **metadata version** - content version + mode/uid/gid + derived `capabilities`/`fs_flags` + effective `kept` + xattr hash. The system re-reads an item only when this moves (`item-index.md`).
- **generation** - per-row counter bumped when ns-mtime or inode evidence shows a change size+second-mtime cannot; it is what moves the content version (`item-index.md`).
- **breaker** - per-location circuit breaker, 2 s doubling to 60 s (300 s for a key agent that is not ready), failing calls fast; calls **wait** for an attempt already in progress, bounded by that attempt's own remaining 60 s. The backoff is also a **reconnect schedule**: the agent attempts unprompted when it expires. Auth and host-key failures bypass it and stop reconnection until a `set` change, `agent restart` or `debug breaker <name> --connect` (`offline.md`).
- **collect connection** - the verification connection the *agent* makes during `add` and `set host|user|port|identity`, prompts relayed to the CLI; twice at most, `IdentityAgent=none` first (`secrets.md`).
- **in-flight set** - paths with an upload in progress; change detection skips them so our own writes never look like remote changes (`writes.md`).
