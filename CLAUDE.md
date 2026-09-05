# SSH Drive

A no-GUI macOS app that mounts remote SFTP locations into Finder through Apple's File Provider
framework (like Mountain Duck / iCloud Drive). Files are dataless placeholders until opened; cached
content is TTL-evicted unless pinned; mounts survive reboot, sleep and network loss; auth is whatever
the user's own `ssh` already does. Everything is driven by the `sshdrive` CLI. The whole plan lives in
`DESIGN.md` (4238 lines) - this file is the map to it, not a replacement.

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
| Release signing | Developer ID Application `6C055553C6A361398A3CC48654E1FADC14660D05` (cert `T9DF89U2YU`), profile `~/Developer/SSH_Drive_Developer_ID.provisionprofile` on the VM, notarization by App Store Connect API key `~/Developer/AuthKey_*.p8` |
| Domain identifier | the location's UUID |

Platform facts a coder must respect (§2): minimum macOS **14** (develop/test on 14/15). The appex is
sandboxed, ephemeral, has **no network entitlement** and cannot reach `~/.ssh`, `SSH_AUTH_SOCK` or
spawn processes. `NSFileProviderReplicatedExtension`; one `NSFileProviderDomain` per location, mounted
under `~/Library/CloudStorage/`. `item(for:)` is called constantly and must be answered from local
state. `keychain-access-groups` is a restricted entitlement needing a provisioning profile, which only
a bundle can embed - so the agent (the bundle's main executable) is the only process with keychain
access. `evictItem` evicts a directory recursively and works on the root container too
(S4, 2026-09-04); the TTL loop still goes file by file because a TTL is per file. SFTP v3
carries nine status codes and no errno.

Processes and modules (§3):
- **Agent** (`Contents/MacOS/SSH Drive`, the host executable): `SMAppService` login agent, not
  sandboxed. Owns `ssh`, SFTP, the index (sole writer), change detection, eviction, domain lifecycle,
  keychain, and the XPC server. Everything of consequence lives here.
- **Extension** (`Contents/PlugIns/SSHDriveFileProvider.appex`): thin XPC client, no state, no
  sockets; reads `index.sqlite` read-only for `item(for:)` and the working set only.
- **CLI** (`Contents/MacOS/sshdrive`): pure XPC client; even `add` and `passwd` connect from the agent.
- **askpass** (`Contents/MacOS/sshdrive-askpass`): pure XPC client, holds nothing, relays `ssh` prompts.
- **helper**: static Rust binary shipped in `Contents/Resources/helper/`, uploaded to the server (§6.4 tier 2).
- `Packages/SSHDriveCore` modules: `Config`, `Secrets`, `SFTP`, `SSHProcess`, `Index`, `XPCProtocols`, `Logging`.

## Repo layout (intended)

`project.yml` (xcodegen spec at root; `xcodegen generate`, then `xcodebuild`) ·
`Packages/SSHDriveCore/` · `Apps/Agent/` (host exe `SSH Drive`) · `Apps/FileProvider/` (appex) ·
`Apps/CLI/` (`sshdrive`) · `Apps/Askpass/` (`sshdrive-askpass`) ·
`Resources/LaunchAgents/org.shirls.sshdrive.agent.plist` (must land at
`Contents/Library/LaunchAgents/` in the bundle) · `helper/` (the `sshdrive-helper` Rust crate, §6.4
tier 2; `cargo test` runs on this Linux box, `scripts/build-helper.sh` emits
`Resources/helper/` which `mac-build.sh` copies into the bundle, and neither is in git) ·
`.github/workflows/helper.yml` (the cross-compile job of §10.1) · `docs/` (spike runbooks and
results, `troubleshooting.md`, `release.md`; also the Pages site) · `scripts/`
(`mac-build.sh`, `build-helper.sh`, `release.sh`) · `packaging/homebrew-tap/`
(the cask, staged: the tap is the separate repo `alecdwm/homebrew-tap`, which does not
exist yet) · `README.md` (the user-facing one) · `dist/` on the Mac only, never in git:
`release.sh` writes `SSH-Drive-<version>.dmg` there and `mac-build.sh`'s `--delete` rsync
wipes it.

## Working rules

- **This Linux box has no Swift toolchain.** Builds run on a headless Mac VM over ssh:
  `scripts/mac-build.sh` syncs the tree to `alec@100.114.204.5:~/sshdrive`, runs xcodegen, `swift test`
  and an ad-hoc signed `xcodebuild` (`app` or `test` argument to run one half). The VM has Xcode 26.4
  on macOS 26.4, no GUI, no signing identities, no passwordless sudo. Finder-dependent spike questions
  need a real Mac; see `docs/spikes/`. On Linux: edit code, then run the script.
- **Never read `DESIGN.md` whole.** Use the section index below and `sed -n 'A,Bp' DESIGN.md`. Reading
  the whole file costs ~60k tokens and is almost never justified.
- **Delegate.** The top-level session orchestrates: it hands section-scoped briefs (explicit line
  ranges) to Opus subagents for reading and coding, and uses Sonnet for mechanical work (renames,
  boilerplate, file moves, test scaffolding). Subagents get the ranges, not the file.
- **`DESIGN.md` is the source of truth.** When code and doc diverge, the doc wins unless the divergence
  was a deliberate decision; then add a dated entry to **§13 Decisions** (`- **<thing>** … (§N)`, with
  the date) and fix the body section it points at. §13 entries are pointers only; the reasoning must
  live in the named section and nowhere else.
- **Do not run mutating git commands** (commit, push, checkout, branch, merge, rebase, reset, add, …)
  unless explicitly asked. Read-only git is fine.

## The spike testbed (`testbed/`)

Eleven real SSH servers for the milestone 2 (S2), milestone 6 (S7 tiers 0-1) and milestone 9
(S7 tier 2) work: Debian and Alpine
targets, every login-shell shape, an external `sftp-server`, keyboard-interactive, `MaxSessions 2`,
a busybox `find` without `-cmin`, and a two-hop `ProxyJump` chain. `docker compose up -d` in
`testbed/`, **on the Mac that hosts the build VM** (OrbStack), never on this Linux box. The account
table, the `~/.ssh/config` stanzas and the per-service smoke tests are in `testbed/README.md`; read
that before using it.

| Reaching it from the VM | |
|---|---|
| Address | `192.168.64.1` - the Mac's vmnet gateway address, ports `2201`-`2208` and `2210` |
| Reachable by | the build VM and the Mac itself. Not the LAN, not the tailnet, not this box |
| Keys | `~/.ssh/sshdrive-spike` on the VM, and `~/.ssh/sshdrive-spike-enc` (passphrase `spike-passphrase`) |
| Passwords | `spike-password`, plus `spike-password-a` / `spike-password-b` for the two bastions |
| Behind the chain | `bastion-b` and `inner` have no published port and are reachable only through `hop@192.168.64.1:2210` |

Verified from the VM on 2026-09-04, and the traps that pass found (details in `testbed/README.md`):

- **An open port is not a running server.** docker's proxy completes the TCP handshake before sshd
  is listening, so readiness is the banner: `nc -G 3 -w 4 192.168.64.1 2201 </dev/null | head -1`.
- **`deb-shells`' `bashbg` account hangs any reader that waits for EOF** - which is the case §9.2's
  sentinel exists for. Give every exec-channel read a deadline, in test harnesses too.
- **A `-J` chain needs the *jump* host's key in `known_hosts` already**; `-o StrictHostKeyChecking`
  on the command line does not reach the `-W` children, only a `~/.ssh/config` alias does.
- **Killing an `ssh`/`sftp` that used `-J` leaves its `-W` children alive**, holding the pipe open.
  The same orphan problem §6.1 describes for our own masters.
- **A published port can be dead while the container is healthy.** `alp` (2206) accepted TCP and
  answered nothing; its sshd was listening and had logged no connection at all, so the broken thing
  was OrbStack's forward. `docker compose up -d --force-recreate <svc>` rebuilds it, and the volumes
  mean no re-seed and no `known_hosts` churn.
- Containers see connections coming from the docker bridge gateway (`192.168.117.1`), never from the
  VM, so sshd logs and `Match Address` cannot tell clients apart.
- **Current busybox has no `find -cmin`.** BusyBox 1.36.1 on Alpine 3.20 answers
  `find: unrecognized: -cmin`; it has `-mmin` and `-newer FILE` only. §6.4 and §13 now say so
  (2026-09-04); the ladder is unchanged, but the `-mmin` fallback is every busybox server's path.
  Its `find --version` prints `find: unrecognized: --version` **and exits 0**, so a flavour probe
  keyed on the exit status calls every busybox server GNU; ours reads the `busybox` banner and the
  `-cmin` answer. The cost of the fallback is measured, not assumed: a `chmod` on a file with an
  old mtime is found by `-cmin` and missed by `-mmin` (S7, 2026-09-04).
- The Alpine data trees come from `entrypoint.sh`'s shell fallback (no perl in the image). It used
  to diverge from the perl branch - unpadded names, 29-byte files, no `weird/utf8-café`; fixed
  2026-09-04, but an already-seeded volume keeps the old shape until `.testbed-seeded` is deleted
  and the service restarted (`testbed/README.md`).

## Section index of DESIGN.md

Regenerate after any edit: `grep -nE '^#{2,4} ' DESIGN.md`

| Lines | Section | What a coder finds |
|---|---|---|
| 1-16 | preamble | "the agent" = ours; "key agent" = ssh-agent/1Password/Secretive |
| 17-76 | §1 Goals and non-goals | SFTP only, no GUI, no trash, no multi-user; the auth promise and its exceptions |
| 77-107 | §2 Platform facts | the File Provider / OpenSSH / launchd facts every design choice rests on; minimum macOS 14 |
| 108-193 | §3 Components | process split, why the agent owns everything, group-container layout |
| 194-230 | §3.1 Identifiers | the table above, plus per-target entitlements |
| 231-281 | §4 Location model | `config.json` location schema field by field; `displayName` renames in place (S9) |
| 282-325 | §4.1 Reusing `~/.ssh/config` | `ssh -G` resolution, attribution by diffing against `-F /dev/null`, the fixed override set |
| 326-599 | §4.2 Secrets | askpass token protocol, prompt classification table, keychain keying, two-pass collect connection, touch-key refusal, the 60 s authentication deadline (300 s for the collect connection) and its re-arm |
| 600-629 | §4.3 Host keys | `known_hosts` only; `ask` at `add`, `yes` + `UpdateHostKeys=no` after |
| 630-631 | §5 The File Provider extension | (heading) |
| 632-668 | §5.1 Responsibilities | system-call -> agent-action table; error mapping to `NSFileProviderError` |
| 669-782 | §5.2 Talking to the agent | XPC shape, FileHandle passing, the read-only WAL index reader, `meta` table, code requirement, progress/cancel |
| 783-1060 | §5.3 Item identifiers and the index | **the SQLite schema**, identifier rules, content/metadata version formula, one-transaction listings and their nesting, anchors and why the working set never reports an empty change set, no tombstones (and the local-only exception), backup + restore-into-live + reconcile-against-replica and when the walk runs |
| 1061-1231 | §5.4 Names, permissions, attributes | case/UTF-8 collisions, mode -> capabilities and `fileSystemFlags`, no trash and Finder's exact wording, local xattrs and what the system will and will not tell us about them, Finder tags through `tagData` and what S10 measured, `.DS_Store` (which never reaches us) |
| 1232-1380 | §5.5 Writes, conflicts, atomicity | temp+rename upload protocol, case-only renames, post-upload lstat, in-flight set, conflict copies (and the **retried** evict that makes them work), stale temp files, recursive delete |
| 1381-1417 | §5.6 Offline behaviour | situation -> behaviour table; what the system's own retry does and does not do; when `disconnect(reason:)` is and is not used |
| 1418-1555 | §5.7 Symlinks | lexical inside-the-root check, two root spellings, relative rewrite, the `readlink` per link, what Finder draws, hidden-link collisions |
| 1556-1557 | §6 The background agent | (heading) |
| 1558-1935 | §6.1 SSH process management | **the exact `ssh` command lines**, master/mux rules, orphan cleanup **and its kill**, exit classification, `ProxyJump` chain building, login-shell env snapshot, the `MaxSessions` probe |
| 1936-2024 | §6.2 SFTP client | wire protocol scope, pipelining, transfer scheduler and what the six-fetch ceiling does and does not bound, per-request deadlines, why not a library |
| 2025-2091 | §6.3 Fail fast when offline | `NWPathMonitor`, circuit breaker, bounded waiting, the backoff as a **reconnect schedule**, the one retry a read gets, `ConnectTimeout=15` |
| 2092-2146 | §6.4 Remote change detection | the three tiers, scope, selection ladder (incl. the *held* channel tier 2 needs), poll schedule |
| 2147-2152 | Tier 0: SFTP poll | `readdir` every root |
| 2153-2226 | Tier 1: remote sweep | the two `find` invocations, `-cmin`, the server-clock window as elapsed time, GNU `-printf`, what a `stat` per entry costs, the `./` root spelling and the non-UTF-8 root |
| 2227-2276 | Lifetime of remote processes | the heartbeat wrapper (15 s ping / 60 s timeout), and that `ClientAliveInterval` does not help |
| 2277-2392 | Tier 2: remote helper | targets, deployment and verification (incl. the self-computed digest), the NDJSON protocol and how its stdin is relayed through a FIFO, ignore list, FreeBSD kqueue caveat |
| 2393-2446 | Mass-deletion guard | thresholds, `held` table, re-check schedule, `.cannotSynchronize` vs `.noSuchItem` as S5 measured them, and why pending items are held |
| 2447-2505 | §6.5 The root set | `materialized` / `pinned` / `viewed` reasons, the 256 cap, tier-0 rotation, and that there is no per-folder refresh |
| 2506-2513 | §6.6 Eviction and pin maintenance | where the timers live |
| 2514-2617 | §7 Cache eviction (TTL) | the 5-minute loop, what the TTL means and why atime is read but not decided on, TCC, the opaque eviction errors, what `evict --all` does with a pin in place, "anything that opens files downloads them" |
| 2618-2706 | §7.1 Pinning | pinned/excluded markers vs kept effect, the five pin steps incl. the replica lookup an unseen path needs, `contentPolicy` |
| 2707-2811 | §7.1.1 Nested items | the three invariants and the five-situation table - read before touching pin code |
| 2812-2851 | §7.1.2 Pinning the root | why the root is not a special case |
| 2852-3016 | §7.2 Finder context menu | the two custom actions and the exact spelling their activation rules need, why the eager policy rather than `allowsEvicting` is the guarantee, why dropping the capability changes nothing, the re-assert safety net, the decoration badge and the three silent traps in declaring one |
| 3017-3167 | §8 The CLI | every command and flag, verbatim; `logs` and its two-halved predicate; `agent stop` shuts the masters down |
| 3168-3291 | §8.1 Capability report | the probe, the feature/level catalogue, `status` output format, the helper's `note:` list |
| 3292-3335 | §9 Security | the security properties in one list |
| 3336-3400 | §9.1 Path containment | the `RelativePath` chokepoint, canonical root, never descend through a link - **including on enumeration** |
| 3401-3494 | §9.2 Remote command execution | `sh -s` + stdin script + sentinel, quoting rules, the external `sftp-server` workaround, the helper's relay FIFO as the one exception to `</dev/null` |
| 3495-3597 | §10 Packaging and install | targets, CI, cask postflight/uninstall/zap, `KeepAlive` semantics, upgrade handover, the Local Network prompt on first connect |
| 3598-3703 | §10.1 Repository and hosting | GitHub layout, release flow, which helper targets CI builds and how, tap naming, **the profile-certificate rule, the signed DMG and the notarization credentials** |
| 3704-3720 | §11 Spikes | S1-S10, each with its question and why it matters |
| 3721-3770 | §12 Milestones | the ten milestones and which spikes fold into each |
| 3771-4208 | §13 Decisions | one-line pointers to every settled question - **start here** when orienting |
| 4209-4241 | §14 Future work | explicitly out of v1 (incl. the worked-out inotify tier design) |

## Milestones (§12)

- [x] **1. Skeleton** - all four targets sign and launch, XPC between them, the extension's read-only
      index reader (kept or dropped on S3's measurement), `sshdrive doctor` green, and a **fake
      backend** behind `SFTPTransport` that stays as the test double forever. Spikes **S1, S3
      (fake-backend part), S4, S6**. *Done 2026-09-04 except notarization, which is milestone 10:
      scaffold written 2026-09-03, compiles Debug+Release, signs with a real Apple Development
      identity and the embedded profile, launches under launchd, XPC works, the domain mounts.
      Spikes: **S1, S4 and S6 done**; S3 done bar s3-9 to s3-14. S1 c2 is closed as "Finder
      offers no cancel control", so the `Progress` cancellation belongs in a milestone 3
      test. See `docs/spikes/`.*
- [ ] **2. Transport** - `-N` master + mux clients, agent-built `ProxyJump`, login-shell snapshot,
      askpass token protocol + keychain, SFTP client, `RelativePath`, `sh -s` scripts. Spike **S2**.
      *Modules written and merged 2026-09-04; 214/214 package tests, and three real mounts on the
      VM through `~/Library/CloudStorage` (plain key, a two-hop `ProxyJump` chain with a password
      on each hop, an encrypted key with its passphrase in the keychain), each listed, read,
      written, renamed and deleted. `sshdrive debug ssh add` was the hook that created one; the
      real `add` replaced it in milestone 3 and the hook is gone. **S2 is answered except the six items that need a real Mac** (Tailscale
      `none`, 1Password/Secretive `IdentityAgent`, `UseKeychain`, FIDO touch, the deadline against
      a touch, the screen-unlock and present-user re-arm). Still open inside milestone 2: the
      second, bulk SFTP channel and the transfer scheduler (milestone 3's fetching), and the
      `MaxSessions` probe. See `docs/spikes/milestone-2.md`.*
- [x] **3. Read-only** - `add`/`list`/`show`/`remove`, browsing and fetching, capability probe and
      `status`, permissions mapping, hidden names. Deferred real-server part of **S3** (containment).
      *Done 2026-09-04. Part 1: the section 6.2 transfer scheduler on a second bulk SFTP channel
      (four at once, foreground before background, the window split between them, cancellation
      from the extension's `Progress`), the section 6.1 `MaxSessions` probe (verified against
      `deb-maxsess`: at 2 the bulk channel is dropped and the exec channel kept), section 5.4's
      permissions-to-capabilities mapping against a real `id` and its hidden-name handling,
      directory paging, `fetchPartialContents`, and **S3's deferred containment test, which
      passed after finding that SFTP `opendir` follows a symlink**. Part 2: the whole
      user-facing CLI - `add` with the section 4.1 `ssh -G` display and config attribution,
      the two-pass collect connection of section 4.2 with every prompt relayed to the
      terminal over a CLI callback interface, `list`, `show`, `remove` (with the shared-item
      rule), `set`, `mount`/`unmount`, `status` with section 8.1's capability report, and
      `doctor` extended for the transport. **295/295 package tests.** Proved on the VM
      against seven testbed servers: key auth, a relayed and stored password, a second
      location on the same host that does not prompt, one- and two-hop `ProxyJump` chains
      with a different password per hop, keyboard-interactive, a fresh host key answered no
      then yes, a wrong password, and busybox. See `docs/spikes/results.md`
      (2026-09-04, "milestone 3, part 2").
      Not in milestone 3 and not claimed: `passwd`, `test`, `--password-stdin`, and the
      helper tier the capability report reports as absent.*
- [x] **4. Read-write** - create/modify/delete/rename/move, temp+rename uploads, conflict copies,
      local xattrs, `.DS_Store`, symlinks. Spikes **S8, S10**.
      *Done 2026-09-04. The section 5.5 write half moved into `AgentCore` as
      `RemoteWriter` (temp file, the create-versus-overwrite rename, mode and
      modification-date restore, the post-upload `lstat`, the in-flight set, the
      stale-temp rule, the rename-semantics probe, the conflict check and copy, the
      delete rules), beside `RowBuilder` and `SymlinkPolicy`; the transport gained
      `writeExclusive`, since the conflict check sits between the bytes and the rename.
      Local xattrs and Finder tags travel in one `LocalAttributes` blob hashed into the
      metadata version (schema version 2). **355/355 package tests.** Proved on a real
      mount of `alec@192.168.64.1:2201` and again on `alp` (2206, busybox +
      `internal-sftp`): create, modify, rename in place and across directories, a
      directory subtree move, delete, a refused `rmdir` of a non-empty directory,
      `rm -r`, a locked read-only item, `chmod +x`, a confirmed collision, stale temp
      files, a genuine conflict copy, and a lost master surfacing as `serverUnreachable`
      with the edit in the pending set. **S8 and S10 answered.** See
      `docs/spikes/milestone-4.md` and `docs/spikes/results.md` (2026-09-04, "milestone
      4"). Not in milestone 4 and not claimed: the sync-error list `status` needs to
      show a refused link's message (milestone 5/6), and reconnection, which is why a
      queued write does not flush by itself.*
- [x] **5. Offline hardening** - breaker with bounded waiting, reconnect, queued-write flush,
      sleep/wake, agent-missing behaviour, deadline re-arm. Spike **S5**.
      *Done 2026-09-04. `AgentCore` gained two pure state machines - `CircuitBreaker`
      (§6.3's four rules, time as an argument) and `DeadlineRearmState` (§4.2's two
      triggers and the once-a-minute presence rule) - and the agent gained
      `ReconnectingTransport` with its `ConnectionGate`, which sits between
      `LocationRuntime` and `SSHBackedTransport` and holds the live connection or does
      not. Beside them `PowerEvents` (IOKit, not `NSWorkspace`), `NetworkPathGate`
      (`NWPathMonitor`), `AgentPresence` (`CGEventSource` + `CGSessionCopyCurrentDictionary`)
      and `ScreenLockObserver`. `LocationRuntime.start()` split into a part that always
      runs and `applyConnection()`, which is re-run on every reconnect, so a location whose
      server is down still mounts and still queues writes. **381/381 package tests**, with
      two long-standing flaky scheduler tests fixed. Proved on a real mount of
      `alec@192.168.64.1:2201`: an edit made while the master was `kill -9`ed flushed 20 ms
      after `signalErrorResolved`; two fetches arriving during a 20 s reconnect both waited
      and both succeeded; the will-sleep drop, the wake reconnect and the path gate all
      exercised. **S5 is answered.** Two behaviours were added because S5 measured that the
      system will not do them: the agent reconnects on the breaker's backoff unprompted, and
      a read that meets a silently dead connection is retried once. See
      `docs/spikes/milestone-5.md` and `docs/spikes/results.md` (2026-09-04, "milestone 5").
      Not in milestone 5 and not claimed: `sshdrive test` and `passwd` (the CLI commands
      that clear a stop; the mechanism is there as `debug breaker --connect`), the reconcile
      walk, and s5-7b, the unmatched-content-version half of S5's working-set question.*
- [x] **6. Change detection tiers 0-1** - root set, anchors, poll cadence, sweep, fallback ladder,
      mass-deletion guard. Spike **S7**.
      *Done 2026-09-04. `AgentCore` gained the whole of section 6.4's decision-making as
      pure, clock-injected types - `RootSet` (the three reasons, the 64-per-cycle
      `materialized` rotation, the 256 `viewed` cap, the pin-root exclusion),
      `SweepPlan`/`SweepParser`/`SweepWindow`, `RemoteSweep` (one sweep on one exec
      channel under the heartbeat wrapper, ended by its own closing sentinel),
      `ChangeDetectionLadder`, `MassDeletionGuard` and `PollSchedule` - and the agent
      gained `ChangeDetector` (one per location: the cadence, the tier, the full sweep on
      reconnect, wake, network-up and a fresh working-set anchor, and the 30-minute
      insurance pass), `ReplicaEnumerators` (the system's own materialized and pending
      sets), `LocationRuntime+ChangeDetection` (the guard-aware listing diff, the `held`
      table, `accept-deletions`, the root-set refresh and the sweep's application to the
      index), `IndexReconcile` (section 5.3's health check, the restore **into** the live
      database, the truncate-the-sidecars path and the walk against the replica) and
      `ExtensionPeers`. Index schema version 3: `roots.last_listed`, `held.checks` and
      `held.reason`, and the sweep's server clock in `meta`. **503/503 package tests**
      (was 381), including eight new testbed-backed sweep tests. Proved on real mounts of
      `deb` (GNU `-cmin -printf`) and `alp` (busybox `-mmin`): a file created, modified,
      renamed and deleted on the server by a separate ssh appeared, changed and vanished
      inside the poll interval; a directory deleted with a pending local edit inside it
      was held and released by `accept-deletions`; a 30-of-40 deletion was held and
      reported in `status`. See `docs/spikes/milestone-6.md` and `docs/spikes/results.md`
      (2026-09-04, "milestone 6"). Not in milestone 6 and not claimed: tier 2, the remote
      helper - **done in milestone 9 on 2026-09-05**, so `auto` no longer tops out at sweep; BSD `find`, which the testbed
      cannot provide; and a real server whose clock disagrees with ours, which a container
      cannot be.*
- [x] **7. Eviction** - TTL loop, `evict`, `set cache-ttl`. Uses S4's answers from milestone 1
      (TTL = time since last fetch or save; `evict --all` is one call on the root).
      *Done 2026-09-05, with milestone 8. `AgentCore` gained **`EvictionPlan`** (last use,
      the TTL comparison, the four skips - `never`, directory, local-only, kept - and the
      cache totals `status` prints) and the agent **`CacheEvictor`**, one actor per
      location holding section 6.6's five-minute timer, the pass, `evict <path>` and
      `evict --all`. Milestone 1's `SpikeHooks` were promoted to **`ReplicaAccess`**
      (`evictItem` with and without the doubling backoff, `getUserVisibleURL`, the `lstat`,
      the replica lookup), which the hooks now forward to, so the spikes and the product
      make the same calls. **The one assumption that failed is atime**: it is now read,
      logged and decided on by nobody (2026-09-05, section 7, gotcha 80). Proved on a real
      mount of `alec@192.168.64.1:2201`: a 30 s TTL evicted a file fetched 35 s earlier and
      spared one saved since; the five-minute timer fired with no CLI at all; a pending
      edit was refused and passed over; `evict --all` took 9 items to 0 from one call on
      the root container. See `docs/spikes/milestone-7-8.md` and `docs/spikes/results.md`
      (2026-09-05).*
- [x] **8. Pinning** - `pin`/`unpin`/`pins`, content policy, kept-subtree watching, Finder actions,
      badge. Uses S6's answers from milestone 1 (an unseen path needs the replica lookup;
      the eager policy is what refuses eviction).
      *Done 2026-09-05. `AgentCore` gained **`PinPolicy`/`PinMarkerSet`** - section 7.1.1's
      whole algebra as a value: the effective state from the nearest marker at or above a
      path, the five situations, and the *smallest* marker change that produces the
      asked-for effect (invariant 3) with what it clears beneath it (invariant 2). The
      agent gained **`LocationRuntime+Pinning`**: the marker write, the descendant rewrite
      in one transaction with an anchor each, the root-set bookkeeping, `pins` with
      `--export`/`--import` and the `pins.json` sidecar, the sweep's `-prune` list, the
      tier 0 expansion of a pin root into every known directory under it, and section 7.2's
      re-assert net. `RowBuilder` derives `kept` from the parent row's effective state,
      which is the whole of "descendants the index has never seen need nothing"; the
      extension gained `performAction` and `decorations`, and the appex plist
      `NSFileProviderDecorations`. **548/548 package tests** (was 503). Proved on the same
      mount: a pin on a folder nothing had opened downloaded its subtree including the
      never-enumerated subfolder; a pin on a path with no rows at all worked through the
      replica lookup; a file created on the server under a pin was fetched and its row was
      born kept; an exclusion under a pin stayed lazy and the TTL took it; `pin /`
      downloaded the location and cleared every nested marker; both Finder entries toggled
      the pin from a file and from the window background, and the badge is drawn. See
      `docs/spikes/milestone-7-8.md` and `docs/spikes/results.md` (2026-09-05). Not in
      milestone 8 and not claimed: section 7.2's re-assert net has no route to fire on 26.4
      and stays dormant, and the sidebar row still offers nothing (S6).*
- [x] **9. Remote helper (tier 2)** - Rust binary, CI cross-compilation, deploy/verify/upgrade, NDJSON.
      *Done 2026-09-05. The Rust crate `helper/` (`sshdrive-helper`, one static
      binary, `libc` its only dependency, 443 KB for `linux/aarch64`): inotify read
      directly on Linux, kqueue plus a 60 s sweep on the BSDs and macOS, a `sweep`
      subcommand carrying size/ns-mtime/inode/mode, server-side coalescing, the
      fixed ignore list, and `--version` printing the SHA-256 of its own executable.
      `AgentCore` gained **`HelperManifest`** (the `uname -sm` table),
      **`HelperDeployment`** (the upload verdict, the seven-day rule, the version
      line) and **`HelperEvent`/`HelperEventDecoder`/`HelperControl`** (the NDJSON
      protocol, its framing and its backpressure); the agent gained
      **`HelperDeployer`** (mkdir 700 and the ownership check, the hash comparison,
      temp-name-and-rename upload, re-verify, the stale sweep, removal) and
      **`HelperStream`** (the exec channel, the `ready` handshake, the reader, the
      15 s ping, live root-set updates, death reported to the ladder); `SFTP` gained
      **`HelperDirectory`/`HelperFile`**, the one deliberate exception to §9.1's
      chokepoint. **592 package tests** (was 548) and **54 crate tests**. Proved on
      real mounts of `deb` (glibc) and `alp` (musl + busybox): create 260/129 ms,
      modify 903/308 ms, rename 82/106 ms, delete 78/82 ms, **chmod 76/78 ms** -
      against 60 s at tier 1, and a `chmod` a busybox `-mmin` sweep never sees at
      all. The stream coexisted with two 48 MiB fetches; a `kill -9` of the client
      took the helper off the server in under 10 s; a corrupted binary of the right
      size was re-uploaded; `helper off` removed it and dropped to sweep;
      `deb-maxsess` refused it a channel and said so; `forcesftp` reported no shell.
      **S7's helper half is answered.** See `docs/spikes/milestone-9.md` and
      `docs/spikes/results.md` (2026-09-05, "milestone 9"). Not answered and not
      claimable from here: **FreeBSD kqueue** (no BSD in the testbed) and **armv7**
      (links only, no hardware).*
- [x] **10. Ship** - notarized DMG, cask, `logs`, docs. Spike **S9** applied to `set nickname` if it passed.
      *Done 2026-09-05, and **notarization is done**: `scripts/release.sh` builds Release,
      signs with the Developer ID identity and the hardened runtime, embeds the helper,
      builds the DMG with `hdiutil` (volume `SSH Drive`, the app plus an `/Applications`
      symlink), and notarizes and staples the app and then the DMG - `xcrun notarytool
      submit --wait` returned **Accepted** with no issues, `stapler validate` passed and
      `spctl --assess` says `accepted / source=Notarized Developer ID`. It notarizes with
      an **App Store Connect API key** (`--key/--key-id/--issuer`), because
      `notarytool store-credentials` cannot be run over ssh at all; the
      `--keychain-profile` form is the fallback and the missing-credentials message names
      both. The cask is `packaging/homebrew-tap/Casks/sshdrive.rb` (the tap is a separate
      repo that does not exist yet; `packaging/homebrew-tap/README.md` says where it goes),
      `sshdrive logs [--follow] [<name>]` reads our subsystem **and** fileproviderd's lines
      for the domain, and the docs are `README.md`, `docs/troubleshooting.md` and
      `docs/release.md`. **S9 is answered: yes** - `add(domain)` with the same identifier
      and a new `displayName` renames the domain in place, keeping the mount directory's
      contents, the materialized set and a pending upload, so `set nickname` renames in
      place and section 13's data-loss caveat is gone. Also fixed here: `agent stop` shuts
      every location's masters and mux clients down first, the orphan sweep kills the
      process that owned the socket it removes, the agent handles **SIGTERM** (it had no
      handler, and the default is death by signal, which `KeepAlive` reads as a crash), the
      agent watches its own executable and hands over on an upgrade (section 10.1's vnode
      source), the `unregister` role waits for launchd to drop the job before exiting, and
      the first start removes File Provider domains that no location claims (section 10).
      **606 package tests** (was 592). Proved on the VM: a notarized DMG installed the way
      the cask does, an upgrade over a running install with a materialized tree and a
      pending upload, and a fresh-user install as `sshtest` with a quarantined bundle. See
      `docs/spikes/milestone-10.md` and `docs/spikes/results.md` (2026-09-05, "milestone
      10").
      **The one thing not delivered: the release ships without `keychain-access-groups`.**
      The Developer ID provisioning profile on the VM was issued for the other of the
      account's two Developer ID Application certificates (`D853BADB…` rather than the
      `6C055553…` in the keychain), and a profile whose certificate does not match makes
      AMFI kill the agent at exec - after notarizing perfectly. `release.sh` detects it,
      drops the entitlement with a loud warning and carries on, so the shipped build runs,
      mounts and syncs but cannot use a stored password or key passphrase and `doctor`
      says so. The owner re-creating the profile against certificate `T9DF89U2YU` and
      re-running the script is the whole fix; no code changes. Also not done: `brew style`
      and `brew audit` (no Homebrew on either machine - `ruby -c` is what ran), and
      `passwd`, `test` and `--password-stdin`, which no milestone has claimed.*

Spike-to-milestone summary: S1/S3/S4/S6 -> M1 (S3's containment half -> M3), S2 -> M2, S8/S10 -> M4,
S5 -> M5, S7 -> M6 (tiers 0-1) and M9 (the helper), S9 -> M10.

## Things a coder gets wrong without the doc

1. Transport is the system **`/usr/bin/ssh`** by absolute path with `argv[0]` set to it, plus our own SFTP v3 wire client in Swift. Not libssh2, Citadel or swift-nio-ssh; never a `PATH` lookup (§6.1, §6.2).
2. The master is `ssh -N` with `ControlPersist=no` - with it set, `ssh` forks away and the agent loses the pid, stderr and exit signal. `ControlPath` is `$TMPDIR/sshdrive-<id8>`, never `%C` (collides for two locations on one host; 104-byte socket limit) (§6.1).
3. Mux clients run `-F /dev/null -o BatchMode=yes -o ProxyCommand=/usr/bin/false`; otherwise a missing socket makes `ssh` open a *second, unsupervised* connection instead of failing. A mux client exiting before its channel opened is always "master lost", never an auth failure (§6.1).
4. `ProxyJump` is never handed to `ssh`: cancel it with `ProxyJump=none` and rebuild each hop as the agent's own `ProxyCommand` with the same overrides plus `ControlMaster=no` **and `ControlPath=none`** (`no` alone still attaches to the config's socket). Write the `ProxyCommand` **first** and the cancellation after it, and double a nested hop's `%h`/`%p` once per level (§6.1, §2, item 33).
5. A location that passed the collect connection's first pass runs `IdentityAgent=none` for good; only `agentDependent` locations ever consult a key agent (§4.2, §6.1).
6. askpass holds nothing: it sends the agent a one-time `SSHDRIVE_ASKPASS_TOKEN`, the prompt, `SSH_ASKPASS_PROMPT` and its parent `ssh`'s argv (`sysctl KERN_PROCARGS2`). Keychain items are keyed `password:<user>@<hostname>:<port>` / `passphrase:<keypath>` from `ssh -G`, never the alias, shared across locations. The **host-key question arrives with `SSH_ASKPASS_PROMPT` unset**, exactly like a password prompt, so it is classified by its own text and the hint is only corroboration; `Enter passphrase for key '%.100s'` truncates, so the prompt text alone can never be the key. The three variable names live once, in `XPCProtocols/AskpassEnvironment.swift` (§4.2).
7. Authentication has a **60 s deadline from spawn**, signalled by the control socket appearing; the 15 s `ConnectTimeout` is contained in it, never added. A deadline stop is re-armed for exactly one attempt on screen unlock or a request arriving with input idle < 30 s and the screen unlocked; refusals are never re-armed (§4.2, §6.3).
8. Every remote path goes through the **`RelativePath` chokepoint** - the SFTP layer exposes no string-path API. Zero components is the root. System filenames, CLI paths, sweep output and helper events all pass the same constructor (§9.1).
9. **No tombstones.** A deleted row goes with its pin marker and xattrs; a re-created path is a new item with a new identifier (§5.3).
10. `content_version` is `"\(size)-\(mtime)-\(generation)"` at **every tier** with whole-second mtime, so a tier change is invisible. ns-mtime and inode are separate columns, feed change detection only, and are **reset to null after every upload of ours** (§5.3, §5.5).
11. The extension opens `index.sqlite` read-only in WAL mode for `item(for:)` and the working set; the agent is sole writer. Any SQLite error there answers `.serverUnreachable`, **never `.noSuchItem`** - that deletes the user's file (§5.2).
12. A row is a finished item: `capabilities`, `fs_flags`, `kept` and `link_target` are derived and stored by the agent. The extension never re-derives them and never walks ancestors (§5.2).
13. Every exec channel runs exactly `sh -s` with the script on stdin, values single-quoted through `set --`. Each script prints a random 128-bit sentinel first and the agent discards everything before it, because rc files print on non-interactive startup (§9.2).
14. Nothing on the server runs bare: the wrapper backgrounds its child with `</dev/null`, reads a 15 s heartbeat, and kills the child after 60 s of silence or EOF (§6.4).
15. Sweep windows come from the **server's** clock (`date +%s` printed by the script, stored only after results are applied) and use `-cmin`, with a `-mmin` fallback on **every** busybox - no busybox build has `-cmin`, so that fallback and its `status` note are the ordinary NAS path, not a legacy case (§6.4).
16. The mass-deletion guard holds listing-derived deletions removing >= half a directory and >= 20 items (or emptying a non-empty root), re-checking at 5 and 30 min. Helper delete events apply at once. A fetch of a held item fails `.cannotSynchronize`, never `.noSuchItem` (§6.4).
17. Uploads go to `.sshdrive-upload-<mac8>-<uuid>` then non-overwriting `rename` (create) or `posix-rename@openssh.com` (overwrite), then `setstat` the mode back, then `lstat` for the version. Never write in place (§5.5).
18. A path with an upload in flight sits in the **in-flight set** and change detection skips it; otherwise our own writes come back as remote changes (§5.5).
19. The conflict check compares size and mtime from a fresh `lstat` **and** `generation` from the row - the wire cannot carry generation, and without it a same-size same-second remote change is overwritten (§5.5).
20. `allowsTrashing` is never set (no trash); xattrs and Finder tags stay local and hash into the metadata version; `.DS_Store` is swallowed as a local-only row with its bytes in `local_content` (§5.4).
21. Symlinks are native items, **never followed**, shown only if a lexical check keeps them inside the root under either spelling (canonical `realpath` or user-typed/`$HOME`); absolute in-root targets are rewritten relative for the Mac; failures are omitted from enumeration entirely (§5.7).
22. Pin markers (`pin_state`) live in the index, the sole authority. **Any change to a path's explicit state first deletes every explicit state beneath it**, silently from Finder too, and a pin change rewrites and anchors **every known descendant row** (§7.1, §7.1.1).
23. What stops a kept item being evicted is its **eager `contentPolicy`**, inherited by the system; `allowsEvicting` is deprecated since macOS 13 and dropping it changes nothing - the system reports the bit from `isDownloaded`, not from us (S6, 2026-09-04). An eviction that reaches a kept item anyway is **re-asserted**, not read as an unpin (unless S6 finds a deliberate route) (§7.1, §7.2).
24. The SFTP wire gives status classes, not errno: `ENOSPC`, `EEXIST`, `ENOTEMPTY`, `EXDEV` all arrive as bare `FAILURE` - ask a second question (`lstat`, `statvfs`, `readdir`). Also OpenSSH's `SSH2_FXP_SYMLINK` takes its two paths in the **opposite order from the draft** (§6.2).
25. A pin on a path nothing has ever listed is not done when the rows are reported: the system ingests nothing from the working set alone, so `pin` finishes with `getUserVisibleURL` + one `lstat` of the replica, which is what makes it enumerate the chain (§7.1).
26. Finder tags never arrive as an xattr: they are the item's `tagData`, and the system wipes them on the next re-download if the item does not return them. It also only reports xattrs it considers syncable (§5.4).
27. A corrupt index is restored **into** the live database via `sqlite3_backup_init` (never by replacing the file: the `-wal`/`-shm` sidecars and the extension's open reader belong to the old inode), then reconciled against the replica under `meta.reconciling` (§5.3).
28. The domain's `displayName` is the **bare nickname**: the system prepends the app name to the mount directory and to the sidebar label itself (§2, §4).
29. **A folder is enumerated once, ever.** Revisiting it in Finder, or a remote change landing while it is open, produces no container-enumerator call at all; everything after the first listing arrives through the working set (§6.5).
30. The system **believes whatever version a `modifyItem` reply carries** - it never re-fetches and never re-offers - so a conflict copy must `evictItem` the item after returning the remote one, and `.filenameCollision` from `createItem` is retried for ever with no alert (§5.5).
31. A custom action's activation rule binds **`fileproviderItems`** (lower-case p) as a **key path**, not a `$` substitution variable. Either mistake drops the menu entry silently; `fileproviderctl evaluate <path>` is how to check (§7.2).
32. Finder contributes exactly two File Provider entries, **"Download Now"** or **"Remove Download"** by `isDownloaded`, and draws no built-in "Keep Downloaded" for us. Our two actions land **at the bottom of the contextual menu, top level**, and on the window background, but **never on the sidebar row** - so a whole location is pinned only from the CLI (§7.2).
33. **`-o ProxyCommand=…` is written before `-o ProxyJump=none`.** Both keywords write the same field and `ssh` takes the first, so the reverse order makes OpenSSH discard the `ProxyCommand` outright and the master then resolves a hostname that only exists behind the bastion. A nested hop's `%h`/`%p` are doubled once per level it sits below the master (`%%h:%%p` at hop *n-1*), because `ssh` percent-expands the whole string before `/bin/sh -c` sees it; without that, hop 1 dials the destination. A `ProxyJump` in a location's own `sshOptions` reaches `ssh -G`, where the chain builder wants it, and is stripped from the master's command line (2026-09-04, §6.1).
34. **Every sentinel's NUL is printed by a `printf` of its own.** `printf "\0<sentinel>"` reads `\0` and the octal digits after it as one character, so a sentinel beginning with a digit silently loses its first bytes and the marker is never found (§6.1, §9.2).
35. **Every `sh -s` script is one `{ … }` group ending in an `exit`.** A compound command must be parsed whole before any of it runs, which is what stops the heartbeat reader eating the script's own tail off the same stdin - and `.` with no argument is a POSIX special builtin that ends a non-interactive shell outright (§9.2).
36. **The heartbeat wrapper reads heartbeats from a descriptor duplicated in the parent, and every subshell clears the `EXIT` trap;** without either it kills its own healthy child seconds after starting it. Its stamp file is `touch`ed, never `:`-redirected, and the `sleep`-and-mtime branch is the *ordinary* Linux path, because an exec channel runs `sh` and Debian's `sh` is dash (§6.4).
37. **A `ForceCommand internal-sftp` account may answer an exec channel with a plain sentence,** `This service allows sftp connections only.`, rather than SFTP framing. The probe recognises both and reports "no shell access (ForceCommand)", never "shell output unusable" (§9.2).
38. **`limits@openssh.com` sizes the request, not the window.** It says nothing about how many requests may be outstanding, so the chunk size is the server's and the depth of sixteen is ours (§6.2).
39. **An SFTP channel is a mux client of the master** (`ssh $MUX -s <host> sftp`), and the wire client sits on the same `ByteStream` an exec channel hands over - one definition, in `SSHProcess`, which `SFTP` depends on. `SFTPSubprocess`, which spawns an `ssh` of its own, is a test path only (§6.1, §6.2).
40. **stderr distinguishes no key-agent state.** A missing socket, a dead socket and a *locked* agent all exit with the same bare `Permission denied (publickey)` at `LogLevel=ERROR`, so the pre-spawn socket probe is the only signal; `agent refused operation` corroborates, it does not decide (2026-09-04, §6.1).
41. **SFTP `opendir` follows a symlink,** so every listing re-`lstat`s its own directory before `readdir`: a directory swapped on the server for a link to `/etc` is otherwise read straight through and every name under it gets a row (2026-09-04, S3, §9.1).
42. **The six-fetch ceiling bounds an eager subtree, not the queue.** Eight files opened at once from a shell arrive as eight simultaneous foreground `fetchContents` calls, so a transfer past the ceiling is admitted and counted, never refused (§6.2).
43. **A directory listing is written in one transaction.** Row by row, a 10,000-entry directory is 10,000 autocommits and `ls` of the mount answers `fts_read: Operation timed out` (§5.3).
44. **The `MaxSessions` probe asks "may I hold three channels at once",** not "what is `MaxSessions`", and proves a channel open by completing the SFTP handshake on it: `ssh` spawns successfully whether or not the session was granted. The answer is cached per location, because the agent never sees a server banner to key it on (§6.1).
45. **The index's transaction helper nests.** §5.3's "a listing is one transaction" wraps calls that are each a transaction of their own (`appendAnchor`, `delete`), and SQLite has no nested `BEGIN`: below the outermost level it is a `SAVEPOINT` (§5.3).
46. **The collect connection of `add` runs to 300 s, not 60.** §4.2's deadline exists because nothing may wait for a human unattended; a person *is* at the keyboard for that one connection. The master `add` brings up afterwards carries the 60 s (§4.2).
47. **The CLI exports an object.** The agent relays the collect connection's prompts back along the same connection, so the listener hands a `sshdrive` peer the CLI callback interface and everyone else the extension's - the same rule that gives askpass its own (§4.2, §5.2).
48. **The CLI's stdout is unbuffered.** The agent writes relayed prompts through the file descriptor; a buffered `print` from the CLI's own report would land out of order behind them whenever stdout is a pipe (§8).
49. **The conflict copy's eviction has to be retried and the working set signalled.** An `evictItem` straight after the `modifyItem` reply is refused `NSFileProviderErrorNonEvictable` (-2008) - the system is still finishing the modification - so it retries with a doubling backoff from 0.25 s; and the copy is a new sibling in a folder that will never be enumerated again, so its anchor needs a working-set signal or Finder never shows it (2026-09-04, §5.5, §6.5).
50. **The xattr hash does not prevent a retry loop, because there is none.** A tag change is not re-offered even when the reply carries the version the item already had. The hash is what makes a change the **agent** makes reach the system - a restore from the index backup - and nothing else (2026-09-04, S10, §5.4, §5.3).
51. **Finder tags are an `NSKeyedArchiver` archive in `tagData`,** never an xattr: `changedFields` carries `NSFileProviderItemTagData` (`0x10`) with an empty `extendedAttributes`. Stored and served opaquely, never parsed (2026-09-04, S10, §5.4).
52. **A `.DS_Store` written into the mount never reaches the extension.** The system keeps it in the replica and never asks anyone to upload it, so §5.4's local-only path exists for other writers, not for Finder (2026-09-04, §5.4).
53. **A local-only row survives a listing that does not mention it** - the one exception to "deleted rows are deleted", and without it the first listing after the create takes the user's file (§5.3, §5.4).
54. **Every symlink a listing reports costs a `readlink`:** SFTP v3's `readdir` carries attributes but no target. Finder then draws the link as Kind **"Alias"** with the arrow badge, dangling or not, with no broken-link marker (2026-09-04, S8, §5.7, §6.2).
55. **A refused `ln -s` is a sync error, not a message.** The create succeeds locally and the refusal comes back as the item's `uploadingError` with the system's own wording, so §5.7's sentence only reaches the user through `sshdrive status` (2026-09-04, S8, §5.7).
56. **`launchctl kill` plus `open -g` does not reinstall the agent** - launchd brings the old binary back before `ditto` finishes and `open -g` then does nothing. Use `sshdrive agent restart`, and check `ping`'s `interfaceVersion`. Related: `pgrep` lists killed mux clients as zombies until the agent reaps them, and a restarted location can hold two masters (2026-09-04).
57. **macOS asks for Local Network access in the app's name on first connect,** which every NAS on the user's own network will hit; no entitlement suppresses it and a launchd agent has no window to put it over (2026-09-04, §2, §10).
58. **`signalErrorResolved(.serverUnreachable)` is the only thing that flushes a queued write.** `signalEnumerator` alone does not, and neither does reconnecting; the queued `modifyItem` arrived 20 ms after the signal and not at all without it. §5.6's "fallback" does not exist (2026-09-04, S5, §5.6).
59. **The system re-offers a queued write on a doubling backoff past five minutes, and re-issues a failed `fetchContents` never.** So the agent reconnects on the breaker's backoff **unprompted**, and a read that meets a silently dead connection is retried once through the breaker; a write is not (its source cannot be replayed, and the write is the one thing the system does re-offer) (2026-09-04, S5, §6.3).
60. **The system does not time out an `enumerateItems` held the full 60 s** the breaker may hold a call for, and leaves the extension running. Finder draws a static circular progress ring in place of the dataless badge for the length of the wait, with no alert (2026-09-04, S5, §6.3).
61. **`disconnect(reason:)` works from inside the extension.** With the login item unregistered the domain goes `permanently disconnected` (state 4); the replica listing and queued writes survive, and re-launching the app lifts it and flushes them (2026-09-04, S5, §5.2).
62. **From `fetchContents`, `.noSuchItem` and `.cannotSynchronize` both leave the item in place** - `ESTALE` against `ETIMEDOUT`. The "never `.noSuchItem`" rule is about `item(for:)` and only about it (2026-09-04, S5, §6.4, §5.2).
63. **A pending edit on an item reported deleted comes back as a `createItem`,** which collides with the path still on the server and is then retried for ever with no alert - the save is stranded and the identifier is new. The mass-deletion guard must hold deletions of pending items (2026-09-04, S5, §6.4, §5.5).
64. **Sleep and wake are IOKit, and the constants do not import.** `kIOMessageSystemWillSleep` and friends are `iokit_common_msg()` macros, spelled out as `0xE0000280` / `0xE0000270` / `0xE0000300`; `CGEventType` likewise has no `.any`, so the presence read is `CGEventType(rawValue: ~0)`. The will-sleep message must be acknowledged with `IOAllowPowerChange` (§6.1).
65. **`launchctl setenv` does not reach a launchd agent on macOS 26,** even across `sshdrive agent restart`, so the spike's presence override is a file in the group container (2026-09-04, S5, §4.2).
66. **`scripts/mac-build.sh` rsyncs with `--delete` and there is no `build/` on the Linux side,** so every run wipes the Mac's build directory. Run `signed` last, or `ditto` fails with "Cannot get the real path for source" (2026-09-04).
67. **The local-attributes blob is encoded with `JSONEncoder` and `.sortedKeys` is load-bearing.** The blob is hashed into the metadata version, and without a sorted key order the same attributes encode to two different byte strings *within one process*, the hash moves, and the system re-reads every item the agent holds (2026-09-04, §5.3, §5.4).
68. **The build VM does not honour `pmset sleepnow`** (`error 0xe00002e2`, exit 71): `powerd` holds "Prevent sleep while display is on". `IORegisterForSystemPower` does register there, so the handlers are driven with `sshdrive debug power will-sleep|did-wake` and only the delivery is unproven (2026-09-04, S5, §6.1).

69. **A bare background process on the server survives an abrupt client kill whatever `ClientAliveInterval` is set to.** sshd reaping the session does not reach a child that has left the foreground job: measured alive three minutes later on Debian with it unset, Debian with it at 15/3, and Alpine/busybox with it unset. The heartbeat wrapper is the only thing that ever kills what we started (2026-09-04, S7, §6.4).
70. **`-cmin` and `-printf` each cost a `stat` per entry, and that is what a sweep spends.** Over a million files, warm: 204 ms with `-print0` and no time test, 850-900 ms adding `-cmin`, 1.6-3.0 s adding `-printf`. The ordinary incremental sweep of that tree is under a second and returns one record (2026-09-04, S7, §6.4).
71. **Every sweep root is spelled `./name`.** `find` has no portable `--`, so a top-level directory named `-name` would be read as an option and take the whole sweep with it; the prefix comes back on every path and is stripped before the `RelativePath` constructor (§6.4).
72. **A sweep root whose bytes are not valid UTF-8 never reaches `find`** - `set --` is a String pipeline end to end - so it is dropped from the argv and listed at tier 0 in the same cycle instead (§6.4, §9.2).
73. **busybox `find --version` prints an error and exits 0,** so the flavour probe reads the `busybox` banner and the `-cmin` answer, never the exit status. And `SweepPlan` refuses `-cmin`/`-printf` on a busybox flavour even when the probe claims them: a busybox `-cmin` does not lose a field, it fails the whole sweep (2026-09-04, S7, §8.1, §6.4).
74. **The sweep's server timestamp is stored only after its results are applied, and a truncated sweep stores nothing,** so the next window still covers what the cut-off one missed (§6.4).
75. **A directory rename rewrites `held.dir` as well as `held.path`,** or the guard's 5- and 30-minute re-checks re-list a name that no longer exists and the holds never resolve (2026-09-04, §5.3, §6.4).
76. **The reconcile walk runs after `add(domain)`, never inside `start()`** - it reads the system's replica - so the restore leaves `meta.reconciling` set and the walk is what clears it. A walk that hits its deadline or item cap **still clears the flag**, because the alternative is a domain stalled for ever (2026-09-04, §5.3).
77. **A CLI command naming a location is a touch,** and it has to be: a folder is enumerated once ever, so a user watching a mount from a terminal produces no File Provider traffic at all and the location would sit at the ten-minute cadence while they worked (§6.4, §6.5).

78. **The working set must answer `.serverUnreachable` while its reader is not ready, never an empty change set.** The system launches a fresh extension instance for every working-set signal, so the first `enumerateChanges` on a signalled instance races the `indexReady` round trip; "no changes" at the anchor the system already holds tells it that it is up to date and the change is dropped until something else signals - a deleted file then sits in Finder indefinitely though it is gone from both the server and the index (2026-09-04, §5.3, §5.2).

79. **The orphan control-socket sweep matches on the socket type, not the name.** `$TMPDIR` is shared and `sshdrive-` is not ours exclusively there - the package's own test databases are `sshdrive-nested-<uuid>.sqlite`, and their `-wal`/`-shm` sidecars made `sshdrive doctor` report a clean install as failing, with six "orphaned sockets" it would have deleted. Each candidate is `lstat`ed and only `S_IFSOCK` counts (2026-09-04, §6.1).

80. **atime is not in the TTL's `max`.** Something in the system advances a materialized file's atime minutes after the fetch, deferred and with no read of ours near it, so with atime in the rule the TTL silently became "time since whatever last touched the replica" - a file fetched 280 s earlier survived a 60 s TTL. It is read, logged beside the age the decision used, and decided on by nobody; `last_fetch` and the later of the replica's and the row's mtime are the whole rule (2026-09-05, §7).

81. **A decoration's Info.plist keys are the bare `Identifier`, `BadgeImageType`, `Label` and `Category`,** not `NSFileProviderDecoration`-prefixed spellings and not the `NSExtensionFileProviderAction*` shape beside them, and `BadgeImageType` is a **UTI conforming to `com.apple.icon-decoration.badge`** (the system ships `.badge.pinned`), never an asset name. Every mistake is silent, like `fileproviderItems`. Finder draws a `Badge` at the trailing edge of the Name column, not on the icon (2026-09-05, §7.2).

82. **`evict --all` is one call on the root container only while nothing is *or has just been* pinned.** With a pin in place it meets a kept child and fails as a whole, and straight after `--unpin-all` it fails as `NSCocoaErrorDomain` "The file couldn't be opened" because the system has not re-read the rows whose policy just changed - a single file becomes evictable 5-10 s after an unpin, the container did not within a minute. Both cases fall back to walking the materialized set with §5.5's backoff per file, which leaves the directory rows materialized (2026-09-05, §7, §7.1).

83. **A pin change rewrites the changed row *and every known descendant row*,** because `contentPolicy` is inherited by the system but `userInfo.kept`, the badge and the capabilities are per item and cached until that item's own metadata version moves. Invariant 2 clears every explicit state beneath first, which is what makes the rewrite one value rather than a per-row ancestor walk (§7.1, §7.1.1).

84. **The helper cannot be started `</dev/null` *and* fed on its stdin.** §9.2 starts every background child with no stdin so it cannot swallow the heartbeat lines; §6.4 feeds the helper its root set and its pings on stdin. Only one process may read a pipe, so the wrapper stays the only reader and **relays** each line into a FIFO the helper is given instead (`RemoteScript.stdinRelay`). A server where `mkfifo` fails runs it `</dev/null` with its roots on its argv. And the relay fragment already ends in a `;`: writing `… || break; <relay>; done` makes `;;`, which dash answers with `Syntax error` and the channel dies at once (2026-09-05, §6.4, §9.2).

85. **A hash the build embeds in a binary is not the hash of that binary.** `--version` prints the SHA-256 the helper computes of **its own executable** at startup, which is what makes §6.4's "size plus `--version`" fallback the same check as the `sha256sum` path rather than a weaker one (2026-09-05, §6.4, §9).

86. **Tier 2 needs an exec channel it can *hold*, not merely open.** A sweep spends half a second on one and gives it back; the helper's stream keeps one for the life of the connection. At `MaxSessions 2` the single spare channel is shared with the probe and the 30-minute insurance sweep, so the helper is refused there - `ChannelBudget.allowsPersistentExecChannel` (2026-09-05, §6.1, §6.4).

87. **The helper's `ready` line is what the ladder settles on.** "The first tier that starts successfully" cannot be decided from the channel opening: `sh` may print anything. `ready` (and `error`) are part of the NDJSON protocol, and a non-UTF-8 path travels as `path_b64` because a JSON string is UTF-8 by definition (2026-09-05, §6.4).

88. **The helper's deployment is the one exception to the `RelativePath` chokepoint.** It writes to `~/.cache/sshdrive`, outside every location root by design, so `SFTP` exposes `HelperDirectory`/`HelperFile` - a probe-chosen absolute directory plus one filename component, no `..`, no nesting - and nothing on the File Provider path can build one (2026-09-05, §9.1, §6.4).

89. **Writing over a running helper fails `ETXTBSY`,** which is why §6.4 uploads to a temp name and renames; and **the wrapper's `EXIT` trap does not run when the wrapper is `SIGKILL`ed**, which is every abrupt client kill, so its relay FIFO is swept by the next deployment instead (2026-09-05, §6.4, §5.5).

90. **`aarch64-unknown-freebsd` has no prebuilt `rust-std`** - `rustup target add` refuses it - so it cannot be built or even `cargo check`ed, and the helper's FreeBSD target is x86_64 only. The three musl targets need no `cross` and no C toolchain: `rust-lld` with `-C link-self-contained=yes` (2026-09-05, §10.1).

91. **A provisioning profile only authorises the certificate it was issued for.** A profile carries its `DeveloperCertificates`, and AMFI matches on them: one created against a *different* Developer ID Application certificate than the signing one makes **every** restricted entitlement unsatisfied (`taskgated-helper: Unsatisfied entitlements: keychain-access-groups`, `amfid: -413 "No matching profile found"`), and the agent is SIGKILLed at exec with a `Launch Constraint Violation` - `open -g` says `Launchd job spawn failed`. It signs, verifies, **notarizes and staples** first: notarization never looks at profiles. Adding `com.apple.application-identifier` to "match properly" makes it worse and is the key S1 a1 forbids anyway. `scripts/release.sh` compares the hashes before signing (2026-09-05, §10.1, §3.1).

92. **`xcrun notarytool store-credentials` cannot run over ssh** - "User interaction is not allowed", with the login keychain unlocked - so a headless release notarizes with an App Store Connect API key (`--key`, `--key-id`, `--issuer`). A read-only key notarizes fine but **cannot create a provisioning profile** (`403 FORBIDDEN_ERROR`) (2026-09-05, §10.1).

93. **`SMAppService.unregister()` returns before launchd has dropped the job,** and `status` says `notRegistered` while launchd is still spawning the old record. A `register()` inside that window leaves the job carrying the previous bundle's launch constraint and every spawn dies `EXC_CRASH (SIGKILL (Code Signature Invalid))` on a 10 s retry, for ever. The `unregister` role polls `launchctl print` until the service is gone before exiting, which is what makes the cask's back-to-back postflight safe (2026-09-05, §10).

94. **The agent had no SIGTERM handler, and the default disposition would have made the cask's `signal:` stanza a crash.** Death by signal is an unsuccessful exit, `KeepAlive` with `SuccessfulExit` false restarts at once, and mid-upgrade that is the old bundle. TERM now runs the same shutdown as `agent stop` and exits 0 (2026-09-05, §10).

95. **`add(domain)` can report `NSCocoaErrorDomain 4099` ("connection to com.apple.FileProvider was invalidated") after the call has landed.** Seen on `set nickname` and on the first location start after an upgrade. The domain list is the authority: `addDomain` re-reads `NSFileProviderManager.domains()` before believing the error (2026-09-05, §5.2, §10).

96. **`sshdrive logs` reads fileproviderd's lines too.** Everything the *system* decides about a domain is under Apple's subsystem and never reaches ours, and `--info` must be passed or `log show` hides most of the transport. `/usr/bin/log` is spelled absolutely: zsh has a `log` builtin (§8).

97. **A pending upload survives a bundle replacement and can be re-offered after it,** so the same write can arrive twice; the §5.5 conflict check is what makes that safe, and it produced a conflict copy rather than a loss (2026-09-05, §10, §5.5).

98. **A zsh harness must spell `${=K}`.** zsh does not word-split an unquoted parameter, so `ssh $K …` with `K="-o BatchMode=yes -i key"` passes it as one argument and every remote command fails with `keyword batchmode extra arguments at end of line`. A latency run then "passes" the steps that check for absence, because a file that was never created is also never seen (2026-09-05).

## Glossary

- **root set** - the bounded directory set every tier watches: `materialized` + `pinned` (recursive) + `viewed` (30 min, capped at 256). Nothing else is polled (§6.5).
- **working set** - the File Provider change stream. Only ever a change stream, never a listing; `enumerateItems` on it returns nothing (§5.3).
- **anchor** - an `anchors` row (sequence number + changed identifier + kind) replayed by the working-set enumerator; expiry answers `.syncAnchorExpired` and triggers a full sweep (§5.3).
- **reconcile** - rebuilding the index from the system's replica by walking the mount and calling `getIdentifierForUserVisibleFile(at:)`, under `meta.reconciling`, which stalls all service (§5.3).
- **pin / excluded / kept** - `pinned`/`excluded` are markers on a path; **kept** is the effect at an item (nearest marker at or above it is a pin). Kept is what everything acts on (§7.1, §7.1.1).
- **tier 0 / 1 / 2** - poll (SFTP `readdir`) / sweep (`find` over exec) / helper (our Rust binary, push ~1 s, real renames). `watchMode: auto` tries top down and degrades (§6.4). Tier 2 is real since 2026-09-05; measured 76-903 ms against tier 1's 60 s.
- **helper** - `sshdrive-helper`, the Rust crate in `helper/`. Uploaded to `~/.cache/sshdrive` over SFTP, hash-verified against `Contents/Resources/helper/manifest.json`, run on one held exec channel under the heartbeat wrapper, and speaking NDJSON back. `helper on|off` per location; `HelperDeployer` puts it there, `HelperStream` reads it (§6.4 tier 2).
- **sweep** - one exec-channel `find` pass over the root set within a window from the **server's** clock; also the 30-min insurance pass. **full sweep** = window opened to the last recorded server timestamp, run on reconnect and on fresh anchors (§6.4, §5.3).
- **metadata version** - content version + mode/uid/gid + derived `capabilities`/`fs_flags` + effective `kept` + xattr hash. The system re-reads an item only when this moves (§5.3).
- **generation** - per-row counter bumped when ns-mtime or inode evidence shows a change size+second-mtime cannot; it is what moves the content version (§5.3).
- **breaker** - per-location circuit breaker, 2 s doubling to 60 s (300 s for a key agent that is not ready), failing calls fast; calls **wait** for an attempt already in progress, bounded by that attempt's own remaining 60 s. The backoff is also a **reconnect schedule**: the agent attempts unprompted when it expires. Auth and host-key failures bypass it and stop reconnection (§6.3).
- **collect connection** - the verification connection the *agent* makes during `add`/`passwd`, prompts relayed to the CLI; twice at most, `IdentityAgent=none` first (§4.2).
- **in-flight set** - paths with an upload in progress; change detection skips them so our own writes never look like remote changes (§5.5).
