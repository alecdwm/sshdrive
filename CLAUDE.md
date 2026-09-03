# SSH Drive

A no-GUI macOS app that mounts remote SFTP locations into Finder through Apple's File Provider
framework (like Mountain Duck / iCloud Drive). Files are dataless placeholders until opened; cached
content is TTL-evicted unless pinned; mounts survive reboot, sleep and network loss; auth is whatever
the user's own `ssh` already does. Everything is driven by the `sshdrive` CLI. The whole plan lives in
`DESIGN.md` (3298 lines) - this file is the map to it, not a replacement.

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

## Section index of DESIGN.md

Regenerate after any edit: `grep -nE '^#{2,4} ' DESIGN.md`

| Lines | Section | What a coder finds |
|---|---|---|
| 1-16 | preamble | "the agent" = ours; "key agent" = ssh-agent/1Password/Secretive |
| 17-76 | §1 Goals and non-goals | SFTP only, no GUI, no trash, no multi-user; the auth promise and its exceptions |
| 77-107 | §2 Platform facts | the File Provider / OpenSSH / launchd facts every design choice rests on; minimum macOS 14 |
| 108-193 | §3 Components | process split, why the agent owns everything, group-container layout |
| 194-230 | §3.1 Identifiers | the table above, plus per-target entitlements |
| 231-277 | §4 Location model | `config.json` location schema field by field |
| 278-321 | §4.1 Reusing `~/.ssh/config` | `ssh -G` resolution, attribution by diffing against `-F /dev/null`, the fixed override set |
| 322-560 | §4.2 Secrets | askpass token protocol, prompt classification table, keychain keying, two-pass collect connection, touch-key refusal, the 60 s authentication deadline and its re-arm |
| 561-589 | §4.3 Host keys | `known_hosts` only; `ask` at `add`, `yes` + `UpdateHostKeys=no` after |
| 590-591 | §5 The File Provider extension | (heading) |
| 592-628 | §5.1 Responsibilities | system-call -> agent-action table; error mapping to `NSFileProviderError` |
| 629-742 | §5.2 Talking to the agent | XPC shape, FileHandle passing, the read-only WAL index reader, `meta` table, code requirement, progress/cancel |
| 743-974 | §5.3 Item identifiers and the index | **the SQLite schema**, identifier rules, content/metadata version formula, anchors, no tombstones, backup + reconcile-against-replica |
| 975-1103 | §5.4 Names, permissions, attributes | case/UTF-8 collisions, mode -> capabilities and `fileSystemFlags`, no trash, local xattrs and what the system will and will not tell us about them, Finder tags through `tagData`, `.DS_Store` |
| 1104-1227 | §5.5 Writes, conflicts, atomicity | temp+rename upload protocol, case-only renames, post-upload lstat, in-flight set, conflict copies, stale temp files, recursive delete |
| 1228-1250 | §5.6 Offline behaviour | situation -> behaviour table; when `disconnect(reason:)` is and is not used |
| 1251-1362 | §5.7 Symlinks | lexical inside-the-root check, two root spellings, relative rewrite, hidden-link collisions |
| 1363-1364 | §6 The background agent | (heading) |
| 1365-1674 | §6.1 SSH process management | **the exact `ssh` command lines**, master/mux rules, orphan cleanup, exit classification, `ProxyJump` chain building, login-shell env snapshot, `MaxSessions` |
| 1675-1745 | §6.2 SFTP client | wire protocol scope, pipelining, transfer scheduler and the system's six-fetch ceiling, per-request deadlines, why not a library |
| 1746-1781 | §6.3 Fail fast when offline | `NWPathMonitor`, circuit breaker, bounded waiting, `ConnectTimeout=15` |
| 1782-1828 | §6.4 Remote change detection | the three tiers, scope, selection ladder, poll schedule |
| 1829-1834 | Tier 0: SFTP poll | `readdir` every root |
| 1835-1877 | Tier 1: remote sweep | the two `find` invocations, `-cmin`, server-clock window, GNU `-printf` |
| 1878-1897 | Lifetime of remote processes | the heartbeat wrapper (15 s ping / 60 s timeout) |
| 1898-1982 | Tier 2: remote helper | targets, deployment and verification, NDJSON event protocol, ignore list, FreeBSD kqueue caveat |
| 1983-2021 | Mass-deletion guard | thresholds, `held` table, re-check schedule, `.cannotSynchronize` |
| 2022-2081 | §6.5 The root set | `materialized` / `pinned` / `viewed` reasons, the 256 cap, tier-0 rotation |
| 2082-2089 | §6.6 Eviction and pin maintenance | where the timers live |
| 2090-2162 | §7 Cache eviction (TTL) | the 5-minute loop, the settled atime answer and what the TTL therefore means, TCC, the opaque eviction errors, "anything that opens files downloads them" |
| 2163-2251 | §7.1 Pinning | pinned/excluded markers vs kept effect, the five pin steps incl. the replica lookup an unseen path needs, `contentPolicy` |
| 2252-2356 | §7.1.1 Nested items | the three invariants and the five-situation table - read before touching pin code |
| 2357-2396 | §7.1.2 Pinning the root | why the root is not a special case |
| 2397-2490 | §7.2 Finder context menu | the two custom actions, `NSPredicate` rules over `userInfo.kept`, why the eager policy rather than `allowsEvicting` is the guarantee, the re-assert safety net, the decoration badge |
| 2491-2605 | §8 The CLI | every command and flag, verbatim |
| 2606-2726 | §8.1 Capability report | the probe, the feature/level catalogue, `status` output format |
| 2727-2770 | §9 Security | the security properties in one list |
| 2771-2823 | §9.1 Path containment | the `RelativePath` chokepoint, canonical root, never descend through a link |
| 2824-2892 | §9.2 Remote command execution | `sh -s` + stdin script + sentinel, quoting rules, the external `sftp-server` workaround |
| 2893-2982 | §10 Packaging and install | targets, CI, cask postflight/uninstall/zap, `KeepAlive` semantics, upgrade handover |
| 2983-3041 | §10.1 Repository and hosting | GitHub layout, release flow, tap naming |
| 3042-3058 | §11 Spikes | S1-S10, each with its question and why it matters |
| 3059-3105 | §12 Milestones | the ten milestones and which spikes fold into each |
| 3106-3265 | §13 Decisions | one-line pointers to every settled question - **start here** when orienting |
| 3266-3298 | §14 Future work | explicitly out of v1 (incl. the worked-out inotify tier design) |

## Milestones (§12)

- [ ] **1. Skeleton** - all four targets sign and launch, XPC between them, the extension's read-only
      index reader (kept or dropped on S3's measurement), `sshdrive doctor` green, and a **fake
      backend** behind `SFTPTransport` that stays as the test double forever. Spikes **S1, S3
      (fake-backend part), S4, S6**. *Scaffold written 2026-09-03; compiles Debug+Release on the VM, 33/33 package tests pass 2026-09-04.
      Spikes: S1 done, S3 partly (its Finder half open), **S4 and S6 done 2026-09-04 apart
      from S6's three Finder-menu questions**; see `docs/spikes/`.*
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
15. Sweep windows come from the **server's** clock (`date +%s` printed by the script, stored only after results are applied) and use `-cmin`, with a `-mmin` fallback for old busybox (§6.4).
16. The mass-deletion guard holds listing-derived deletions removing >= half a directory and >= 20 items (or emptying a non-empty root), re-checking at 5 and 30 min. Helper delete events apply at once. A fetch of a held item fails `.cannotSynchronize`, never `.noSuchItem` (§6.4).
17. Uploads go to `.sshdrive-upload-<mac8>-<uuid>` then non-overwriting `rename` (create) or `posix-rename@openssh.com` (overwrite), then `setstat` the mode back, then `lstat` for the version. Never write in place (§5.5).
18. A path with an upload in flight sits in the **in-flight set** and change detection skips it; otherwise our own writes come back as remote changes (§5.5).
19. The conflict check compares size and mtime from a fresh `lstat` **and** `generation` from the row - the wire cannot carry generation, and without it a same-size same-second remote change is overwritten (§5.5).
20. `allowsTrashing` is never set (no trash); xattrs and Finder tags stay local and hash into the metadata version; `.DS_Store` is swallowed as a local-only row with its bytes in `local_content` (§5.4).
21. Symlinks are native items, **never followed**, shown only if a lexical check keeps them inside the root under either spelling (canonical `realpath` or user-typed/`$HOME`); absolute in-root targets are rewritten relative for the Mac; failures are omitted from enumeration entirely (§5.7).
22. Pin markers (`pin_state`) live in the index, the sole authority. **Any change to a path's explicit state first deletes every explicit state beneath it**, silently from Finder too, and a pin change rewrites and anchors **every known descendant row** (§7.1, §7.1.1).
23. What stops a kept item being evicted is its **eager `contentPolicy`**, inherited by the system; `allowsEvicting` is deprecated since macOS 13 and is dropped only to take "Remove Download" out of Finder's menu. An eviction that reaches a kept item anyway is **re-asserted**, not read as an unpin (unless S6 finds a deliberate route) (§7.1, §7.2).
24. The SFTP wire gives status classes, not errno: `ENOSPC`, `EEXIST`, `ENOTEMPTY`, `EXDEV` all arrive as bare `FAILURE` - ask a second question (`lstat`, `statvfs`, `readdir`). Also OpenSSH's `SSH2_FXP_SYMLINK` takes its two paths in the **opposite order from the draft** (§6.2).
25. A pin on a path nothing has ever listed is not done when the rows are reported: the system ingests nothing from the working set alone, so `pin` finishes with `getUserVisibleURL` + one `lstat` of the replica, which is what makes it enumerate the chain (§7.1).
26. Finder tags never arrive as an xattr: they are the item's `tagData`, and the system wipes them on the next re-download if the item does not return them. It also only reports xattrs it considers syncable (§5.4).
27. A corrupt index is restored **into** the live database via `sqlite3_backup_init` (never by replacing the file: the `-wal`/`-shm` sidecars and the extension's open reader belong to the old inode), then reconciled against the replica under `meta.reconciling` (§5.3).

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
