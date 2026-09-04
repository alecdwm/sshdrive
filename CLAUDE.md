# SSH Drive

A no-GUI macOS app that mounts remote SFTP locations into Finder through Apple's File Provider
framework (like Mountain Duck / iCloud Drive). Files are dataless placeholders until opened; cached
content is TTL-evicted unless pinned; mounts survive reboot, sleep and network loss; auth is whatever
the user's own `ssh` already does. Everything is driven by the `sshdrive` CLI. The whole plan lives in
`DESIGN.md` (3403 lines) - this file is the map to it, not a replacement.

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
| Repo / cask | `github.com/alecdwm/sshdrive`; cask `ssh-drive` in tap `alecdwm/tap` (`alecdwm/homebrew-tap`) |
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
`Contents/Library/LaunchAgents/` in the bundle) · `docs/` (spike runbooks and results; also the Pages
site) · `scripts/` (build/sign/notarize, later milestones). A Rust crate for `sshdrive-helper` is
needed by milestone 9.

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

Eleven real SSH servers for the milestone 2 (S2) and milestone 6 (S7) work: Debian and Alpine
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
| 231-278 | §4 Location model | `config.json` location schema field by field |
| 279-322 | §4.1 Reusing `~/.ssh/config` | `ssh -G` resolution, attribution by diffing against `-F /dev/null`, the fixed override set |
| 323-561 | §4.2 Secrets | askpass token protocol, prompt classification table, keychain keying, two-pass collect connection, touch-key refusal, the 60 s authentication deadline and its re-arm |
| 562-590 | §4.3 Host keys | `known_hosts` only; `ask` at `add`, `yes` + `UpdateHostKeys=no` after |
| 591-592 | §5 The File Provider extension | (heading) |
| 593-629 | §5.1 Responsibilities | system-call -> agent-action table; error mapping to `NSFileProviderError` |
| 630-743 | §5.2 Talking to the agent | XPC shape, FileHandle passing, the read-only WAL index reader, `meta` table, code requirement, progress/cancel |
| 744-975 | §5.3 Item identifiers and the index | **the SQLite schema**, identifier rules, content/metadata version formula, anchors, no tombstones, backup + reconcile-against-replica |
| 976-1115 | §5.4 Names, permissions, attributes | case/UTF-8 collisions, mode -> capabilities and `fileSystemFlags`, no trash and Finder's exact wording, local xattrs and what the system will and will not tell us about them, Finder tags through `tagData`, `.DS_Store` |
| 1116-1252 | §5.5 Writes, conflicts, atomicity | temp+rename upload protocol, case-only renames, post-upload lstat, in-flight set, conflict copies (and the evict that makes them work), stale temp files, recursive delete |
| 1253-1275 | §5.6 Offline behaviour | situation -> behaviour table; when `disconnect(reason:)` is and is not used |
| 1276-1387 | §5.7 Symlinks | lexical inside-the-root check, two root spellings, relative rewrite, hidden-link collisions |
| 1388-1389 | §6 The background agent | (heading) |
| 1390-1699 | §6.1 SSH process management | **the exact `ssh` command lines**, master/mux rules, orphan cleanup, exit classification, `ProxyJump` chain building, login-shell env snapshot, `MaxSessions` |
| 1700-1770 | §6.2 SFTP client | wire protocol scope, pipelining, transfer scheduler and the system's six-fetch ceiling, per-request deadlines, why not a library |
| 1771-1806 | §6.3 Fail fast when offline | `NWPathMonitor`, circuit breaker, bounded waiting, `ConnectTimeout=15` |
| 1807-1853 | §6.4 Remote change detection | the three tiers, scope, selection ladder, poll schedule |
| 1854-1859 | Tier 0: SFTP poll | `readdir` every root |
| 1860-1912 | Tier 1: remote sweep | the two `find` invocations, `-cmin`, server-clock window, GNU `-printf` |
| 1913-1932 | Lifetime of remote processes | the heartbeat wrapper (15 s ping / 60 s timeout) |
| 1933-2017 | Tier 2: remote helper | targets, deployment and verification, NDJSON event protocol, ignore list, FreeBSD kqueue caveat |
| 2018-2056 | Mass-deletion guard | thresholds, `held` table, re-check schedule, `.cannotSynchronize` |
| 2057-2115 | §6.5 The root set | `materialized` / `pinned` / `viewed` reasons, the 256 cap, tier-0 rotation, and that there is no per-folder refresh |
| 2116-2123 | §6.6 Eviction and pin maintenance | where the timers live |
| 2124-2196 | §7 Cache eviction (TTL) | the 5-minute loop, the settled atime answer and what the TTL therefore means, TCC, the opaque eviction errors, "anything that opens files downloads them" |
| 2197-2285 | §7.1 Pinning | pinned/excluded markers vs kept effect, the five pin steps incl. the replica lookup an unseen path needs, `contentPolicy` |
| 2286-2390 | §7.1.1 Nested items | the three invariants and the five-situation table - read before touching pin code |
| 2391-2430 | §7.1.2 Pinning the root | why the root is not a special case |
| 2431-2569 | §7.2 Finder context menu | the two custom actions and the exact spelling their activation rules need, why the eager policy rather than `allowsEvicting` is the guarantee, why dropping the capability changes nothing, the re-assert safety net, the decoration badge |
| 2570-2684 | §8 The CLI | every command and flag, verbatim |
| 2685-2805 | §8.1 Capability report | the probe, the feature/level catalogue, `status` output format |
| 2806-2849 | §9 Security | the security properties in one list |
| 2850-2902 | §9.1 Path containment | the `RelativePath` chokepoint, canonical root, never descend through a link |
| 2903-2971 | §9.2 Remote command execution | `sh -s` + stdin script + sentinel, quoting rules, the external `sftp-server` workaround |
| 2972-3061 | §10 Packaging and install | targets, CI, cask postflight/uninstall/zap, `KeepAlive` semantics, upgrade handover |
| 3062-3120 | §10.1 Repository and hosting | GitHub layout, release flow, tap naming |
| 3121-3137 | §11 Spikes | S1-S10, each with its question and why it matters |
| 3138-3184 | §12 Milestones | the ten milestones and which spikes fold into each |
| 3185-3383 | §13 Decisions | one-line pointers to every settled question - **start here** when orienting |
| 3384-3416 | §14 Future work | explicitly out of v1 (incl. the worked-out inotify tier design) |

## Milestones (§12)

- [ ] **1. Skeleton** - all four targets sign and launch, XPC between them, the extension's read-only
      index reader (kept or dropped on S3's measurement), `sshdrive doctor` green, and a **fake
      backend** behind `SFTPTransport` that stays as the test double forever. Spikes **S1, S3
      (fake-backend part), S4, S6**. *Scaffold written 2026-09-03; compiles Debug+Release on the VM, 33/33 package tests pass 2026-09-04.
      Spikes: **S1, S4 and S6 done**; S3 done bar s3-9 to s3-14. S1 c2 is closed as "Finder
      offers no cancel control", so the `Progress` cancellation belongs in a milestone 3
      test. See `docs/spikes/`.*
- [ ] **2. Transport** - `-N` master + mux clients, agent-built `ProxyJump`, login-shell snapshot,
      askpass token protocol + keychain, SFTP client, `RelativePath`, `sh -s` scripts. Spike **S2**.
- [ ] **3. Read-only** - `add`/`list`/`show`/`remove`, browsing and fetching, capability probe and
      `status`, permissions mapping, hidden names. Deferred real-server part of **S3** (containment).
- [ ] **4. Read-write** - create/modify/delete/rename/move, temp+rename uploads, conflict copies,
      local xattrs, `.DS_Store`, symlinks. Spikes **S8, S10**.
- [ ] **5. Offline hardening** - breaker with bounded waiting, reconnect, queued-write flush,
      sleep/wake, agent-missing behaviour, deadline re-arm. Spike **S5**.
- [ ] **6. Change detection tiers 0-1** - root set, anchors, poll cadence, sweep, fallback ladder,
      mass-deletion guard. Spike **S7**.
- [ ] **7. Eviction** - TTL loop, `evict`, `set cache-ttl`. Uses S4's answers from milestone 1
      (TTL = time since last fetch or save; `evict --all` is one call on the root).
- [ ] **8. Pinning** - `pin`/`unpin`/`pins`, content policy, kept-subtree watching, Finder actions,
      badge. Uses S6's answers from milestone 1 (an unseen path needs the replica lookup;
      the eager policy is what refuses eviction).
- [ ] **9. Remote helper (tier 2)** - Rust binary, CI cross-compilation, deploy/verify/upgrade, NDJSON.
      Until it ships, `auto` tops out at sweep.
- [ ] **10. Ship** - notarized DMG, cask, `logs`, docs. Spike **S9** applied to `set nickname` if it passed.

Spike-to-milestone summary: S1/S3/S4/S6 -> M1 (S3's containment half -> M3), S2 -> M2, S8/S10 -> M4,
S5 -> M5, S7 -> M6, S9 -> M10.

## Things a coder gets wrong without the doc

1. Transport is the system **`/usr/bin/ssh`** by absolute path with `argv[0]` set to it, plus our own SFTP v3 wire client in Swift. Not libssh2, Citadel or swift-nio-ssh; never a `PATH` lookup (§6.1, §6.2).
2. The master is `ssh -N` with `ControlPersist=no` - with it set, `ssh` forks away and the agent loses the pid, stderr and exit signal. `ControlPath` is `$TMPDIR/sshdrive-<id8>`, never `%C` (collides for two locations on one host; 104-byte socket limit) (§6.1).
3. Mux clients run `-F /dev/null -o BatchMode=yes -o ProxyCommand=/usr/bin/false`; otherwise a missing socket makes `ssh` open a *second, unsupervised* connection instead of failing. A mux client exiting before its channel opened is always "master lost", never an auth failure (§6.1).
4. `ProxyJump` is never handed to `ssh`: cancel it with `ProxyJump=none` and rebuild each hop as the agent's own `ProxyCommand` with the same overrides plus `ControlMaster=no` **and `ControlPath=none`** (`no` alone still attaches to the config's socket) (§6.1, §2).
5. A location that passed the collect connection's first pass runs `IdentityAgent=none` for good; only `agentDependent` locations ever consult a key agent (§4.2, §6.1).
6. askpass holds nothing: it sends the agent a one-time `SSHDRIVE_ASKPASS_TOKEN`, the prompt, `SSH_ASKPASS_PROMPT` and its parent `ssh`'s argv (`sysctl KERN_PROCARGS2`). Keychain items are keyed `password:<user>@<hostname>:<port>` / `passphrase:<keypath>` from `ssh -G`, never the alias, shared across locations (§4.2).
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

## Glossary

- **root set** - the bounded directory set every tier watches: `materialized` + `pinned` (recursive) + `viewed` (30 min, capped at 256). Nothing else is polled (§6.5).
- **working set** - the File Provider change stream. Only ever a change stream, never a listing; `enumerateItems` on it returns nothing (§5.3).
- **anchor** - an `anchors` row (sequence number + changed identifier + kind) replayed by the working-set enumerator; expiry answers `.syncAnchorExpired` and triggers a full sweep (§5.3).
- **reconcile** - rebuilding the index from the system's replica by walking the mount and calling `getIdentifierForUserVisibleFile(at:)`, under `meta.reconciling`, which stalls all service (§5.3).
- **pin / excluded / kept** - `pinned`/`excluded` are markers on a path; **kept** is the effect at an item (nearest marker at or above it is a pin). Kept is what everything acts on (§7.1, §7.1.1).
- **tier 0 / 1 / 2** - poll (SFTP `readdir`) / sweep (`find` over exec) / helper (our Rust binary, push ~1 s, real renames). `watchMode: auto` tries top down and degrades (§6.4).
- **sweep** - one exec-channel `find` pass over the root set within a window from the **server's** clock; also the 30-min insurance pass. **full sweep** = window opened to the last recorded server timestamp, run on reconnect and on fresh anchors (§6.4, §5.3).
- **metadata version** - content version + mode/uid/gid + derived `capabilities`/`fs_flags` + effective `kept` + xattr hash. The system re-reads an item only when this moves (§5.3).
- **generation** - per-row counter bumped when ns-mtime or inode evidence shows a change size+second-mtime cannot; it is what moves the content version (§5.3).
- **breaker** - per-location circuit breaker, 2 s doubling to 60 s, failing calls fast; calls **wait** for an attempt already in progress. Auth and host-key failures bypass it and stop reconnection (§6.3).
- **collect connection** - the verification connection the *agent* makes during `add`/`passwd`, prompts relayed to the CLI; twice at most, `IdentityAgent=none` first (§4.2).
- **in-flight set** - paths with an upload in progress; change detection skips them so our own writes never look like remote changes (§5.5).
