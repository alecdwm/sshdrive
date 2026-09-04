# Spike results

One entry per sub-question, newest date first. Steps and expected answers are in
`milestone-1.md` (S1, S3, S4, S6), `milestone-2.md` (S2), `milestone-4.md` (S8, S10 and the
write matrix), `milestone-5.md` (S5), `milestone-6.md` (S7, tiers 0 and 1),
`milestone-7-8.md` (eviction and pinning) and `milestone-9.md` (S7's helper half, tier 2);
this file records only what happened.

---

## 2026-09-05 (milestone 9) - tier 2: the Rust helper, deploy and verify, NDJSON, `helper on|off`

Milestone 9 end to end: DESIGN.md section 6.4's tier 2 as a real static Rust binary we
upload to the server and stream NDJSON from, section 10.1's cross-compilation and sha256
manifest, and the helper half of **S7**, which milestone 6 explicitly left open. Same
headless VM (macOS 26.4.1 arm64, Xcode 26.4, `OpenSSH_10.2p1`), the signed Debug build
installed over `/Applications/SSH Drive.app` with `ditto`, the Docker testbed on the Mac
that hosts it. Steps are in `milestone-9.md`.

**`auto` now climbs to helper.** Every location with a shell, a writable executable
directory, a supported `uname -sm` and a channel it can hold open runs at tier 2, and
`sshdrive status` prints the first **8/8 optimal** any milestone has produced.

**592 package tests, 0 failures** (was 548; 40 skipped without the testbed, and 5 of 5 in
`TestbedHeartbeatTests` with `SSHDRIVE_TESTBED=1`) and **54 crate tests, 0 failures**, with `cargo clippy -D warnings` clean.

### What was built

**The crate, `helper/`** - `sshdrive-helper`, one binary, one dependency (`libc`), no
`serde` and no JSON crate, because every target in section 10.1 has to cross-compile from
a Linux box with no C toolchain and the thing is uploaded over the user's own link.
`opt-level="z"`, `lto`, `panic="abort"`, stripped: **443 KB** for `linux/aarch64`.

- `json` - the NDJSON writer and a small parser for the control lines. The only hard part
  is that a server filename is bytes and a JSON string is UTF-8: a name that is text
  travels as `"path"`, one that is not as `"path_b64"`.
- `proto` - the event shapes and the **coalescer**, which is section 6.4's "server-side
  batching and filtering" as a merge table.
- `paths` - the fixed ignore list, byte-wise containment, and the rule that `..` never
  passes.
- `walk` - the `sweep` subcommand: tier 1's job with size, ns-mtime, inode and mode
  included so no follow-up `stat` is needed, over a **ctime** window.
- `watch_inotify` - inotify read directly rather than through `inotifywait` (section 14),
  which is not installed on a NAS and cannot report a rename at all because it does not
  expose the cookie. `IN_DONT_FOLLOW` for containment, `IN_EXCL_UNLINK`, and `IN_MODIFY`
  deliberately left out because `IN_CLOSE_WRITE` reports the finished write.
- `watch_kqueue` - the FreeBSD/macOS build: kqueue on directories with a name/inode
  snapshot diff, plus its own 60-second sweep for content changes, exactly as section 6.4
  describes. **Compiled and exercised by nothing** (below).
- `control` - the ping deadline and the root-set line, on a thread of its own.
- `sha256` - so `--version` can print the digest of the running executable.

**The Swift side.** `AgentCore` took the decisions: `HelperManifest` (the `uname -sm`
table and the manifest CI writes), `HelperDeployment` (the upload verdict from whatever
evidence the server could give, the seven-day rule for another Mac's version, the
`--version` line), `HelperEvent`/`HelperEventDecoder`/`HelperControl` (the protocol, its
framing and its backpressure). The agent took the I/O: **`HelperDeployer`** (mkdir 700 and
the ownership check, the hash comparison, the temp-name-and-rename upload, the re-verify,
the stale sweep, and the removal `helper off` and `remove` need) and **`HelperStream`**
(the exec channel, the `ready` handshake, the NDJSON reader, the 15-second ping, live
root-set updates, and death reported to the ladder). `ChangeDetector` grew the tier 2 rung;
`LocationRuntime+ChangeDetection` grew `applyHelperEvents`. `SFTP` grew `HelperDirectory`
and `HelperFile` - the one deliberate exception to section 9.1's `RelativePath`
chokepoint, because the helper lives outside every location root by design.

### The mount proofs

Two locations, `m9` on `deb` (Debian, glibc, GNU `find`) and `m9a` on `alp` (Alpine,
**musl**, busybox). Every change is made by a **separate** ssh.

**Latency, against milestone 6's tier 1 on the same steps:**

| Step | `m9` (glibc) | `m9a` (musl) | milestone 6, tier 1 |
|---|---|---|---|
| create -> visible | **260 ms** | **129 ms** | 59,743 ms |
| modify -> new content | **903 ms** | **308 ms** | 104 ms* |
| rename -> new name visible | **82 ms** | **106 ms** | 59,923 ms |
| rename -> old name gone | **85 ms** | **79 ms** | 7 ms* |
| delete -> gone | **78 ms** | **82 ms** | 59,647 ms |
| **chmod -> mode changes** | **76 ms** | **78 ms** | never, on busybox |

\* milestone 6's millisecond rows are the cadence, not the mechanism: everything one
60-second cycle finds arrives together. At tier 2 every row is independent and **every one
is under a second**. The last row is the case S7 measured tier 1 losing - a `chmod` on a
file with an old mtime moves ctime and not mtime, so a busybox `-mmin` sweep provably
misses it. The helper watches `IN_ATTRIB` and reports it on both servers in under 80 ms.

**One static aarch64 binary, two libcs.** The same file runs on Debian 12 (glibc) and on
Alpine (musl), and on both it reports its own digest back:
`sshdrive-helper 0.1.0 linux/aarch64 sha256=bb786789…dbe962`, matching the manifest.

**Beside two SFTP channels.** A 48 MiB file fetched twice concurrently through the mount
while the helper streamed, and a file created on the server during the transfers appeared
in **1,215 ms**. The Mac's side is exactly section 6.1's budget: one `-N` master, two
`ssh -s sftp` mux clients, one `ssh … sh -s` carrying the helper.

**An abrupt client kill.** `kill -9` on the master and all three mux clients at once: the
helper was **gone from the server within 10 s**, well inside the 60-second window - and by
its *own* rule, not the wrapper's, since its stdin is the relay FIFO whose only writer was
the wrapper. The agent reconnected on the breaker's schedule and the next cycle started a
new stream: killed 02:37:55, streaming again 02:39:30, with a full sweep in between.

**A corrupted binary.** Seven bytes overwritten in place, same size, so only a hash can see
it; the agent re-uploaded on its next connection and the file matched the build again.
Writing over the *running* helper failed first with `Text file busy` - `ETXTBSY`, which is
exactly why section 6.4 uploads to a temp name and renames.

**`helper off`/`on`.** Off removes the binary on the spot and the ladder drops to sweep
with `note: the helper is off for this location`; on re-uploads and climbs back.

**`deb-maxsess` (2205)** reports `the server will not give the helper a channel of its own
(MaxSessions 2)` and uploads nothing. **`forcesftp` on `deb-shells` (2202)** reports `the
account has no shell access` and sits at poll.

### Four assumptions that failed

**Section 6.4 asks for two incompatible things about the helper's stdin.** Section 9.2:
"Background children never share the script's stdin. `find` and the helper are started with
`</dev/null`, so the wrapper is the only reader of the heartbeat lines and a child cannot
swallow them." Section 6.4 tier 2: "feed it the root set, and read NDJSON events … The
agent sends a ping line every 15 s in return and the helper exits after 60 s without one."
Both cannot be the channel's stdin, and only one process may read a pipe. The wrapper now
**relays** every line it reads into a FIFO in the helper's own directory, which the helper
is given as its stdin; a server where `mkfifo` fails runs the helper `</dev/null` with its
initial root set on its own argv, and the wrapper is then its only kill switch. Section 6.4
and section 13 record it.

**A hash embedded in the binary cannot be the hash of the binary.** Section 6.4's fallback
for a server with neither `sha256sum` nor `shasum` is "the remote file's size against the
embedded binary plus running it with `--version`, which prints its version and its own
embedded build hash". A constant compiled in is a hash of something else. `--version`
computes the digest of **its own executable** at startup instead, which makes the fallback
the same check as the good path rather than a weaker one - and it is what caught the
deliberate corruption above on a server where `sha256sum` was also available.

**Tier 2 needs a channel it can *hold*, and the `MaxSessions` budget did not model that.**
A sweep opens an exec channel, spends half a second on it and gives it back; the helper's
stream holds one for the life of the connection. At `MaxSessions 2` the single spare
channel is shared by the probe, `sshdrive test` and section 6.4's own 30-minute insurance
sweep, so a helper that never gave it back would cost the location all three.
`ChannelBudget` grew `allowsPersistentExecChannel`, the ladder grew the reason, and 2205
now says so in one sentence.

**`aarch64-unknown-freebsd` cannot be built or even checked.** It is a tier 3 Rust target
with no prebuilt `rust-std`; `rustup target add` refuses it outright. Section 6.4's own
target list stops at `freebsd/x86_64`, so nothing is owed - but section 10.1's release flow
had to say which FreeBSD it means, and the CI workflow now does.

### Three smaller things found on the way

- **A `;` after a relayed line is a `;;`.** The first wrapper wrote
  `… || break; <relay>; done` where the relay fragment already ended in its own `;`. dash
  answered `Syntax error: ";;" unexpected` at line 31, the channel died on the spot, and
  the ladder read it as "the helper would not start" and dropped the location to sweep for
  the session - a correct response to a self-inflicted wound. `RemoteScriptTests` pins the
  shape and `TestbedHeartbeatTests` now runs the relay against **real** `sh` on Debian's
  dash and Alpine's busybox ash, because the shape assertions did not catch it and the
  testbed test would have.
- **The wrapper's EXIT trap does not run when the wrapper is SIGKILLed**, which is every
  abrupt client kill - the case the wrapper exists for - so a relay FIFO is left behind
  each time. `helper off` then removed the binary and could not remove the directory. The
  deployment now sweeps `.sshdrive-helper-in-*` with no age rule; a FIFO with no writer is
  inert.
- **The ladder offers a tier the deployment has not yet earned.** `auto` "tries the tiers
  from the top", so the capability report was written while the tier said `helper` and no
  stream existed, and printed `helper ? at ?` and `● rename detection helper move events`
  from a helper that had not started. The report now requires the stream's own report, and
  a cycle at tier 2 with no stream running falls back to a sweep for that cycle rather than
  doing nothing at all.

### State the VM was left in

No locations, no File Provider domains, no `~/Library/CloudStorage` entries, no `ssh`
masters and no `sshdrive-*` control sockets; `~/.cache/sshdrive` and `~/m9` removed from
2201, 2202, 2205 and 2206, and no `sshdrive-helper` process anywhere. The signed Debug
build is installed at `/Applications/SSH Drive.app` and the agent is running.

---

## 2026-09-05 (milestones 7 and 8) - the TTL loop, `evict`, and pinning end to end

Milestones 7 and 8 together: DESIGN.md section 7's five-minute eviction loop with
`sshdrive evict` and `set cache-ttl`, and section 7.1's pinning - `pin`/`unpin`/`pins`, the
per-item content policy with the inherited-kept rule and explicit lazy exclusions of
section 7.1.1, the replica lookup that makes a pin on an unseen path work, kept-subtree
watching folded into the root set, eviction exclusion for kept items, whole-location
pinning from the CLI, the two Finder context-menu actions through `performAction`, and the
pin badge. Same headless VM (macOS 26.4.1 arm64, Xcode 26.4), the signed Debug build
installed over `/Applications/SSH Drive.app`, testbed up, one real location `m78` on
`alec@192.168.64.1:2201`. Steps are in `milestone-7-8.md`.

**548 package tests, 0 failures** (was 503; 39 skipped without the testbed). The 45 new ones
are `PinPolicyTests` (section 7.1.1's five situations and three invariants),
`EvictionPlanTests` (section 7's rule against an injected clock), `PinQueryTests` (the two
index queries a pin change makes), four `RowBuilderTests` for the kept state a new row is
born with, and one `RootSetTests` for the pin root's exemption from the tier 0 rotation.

### What was built

Two more pure, clock-injected types in `AgentCore`, on the same split every milestone since
5 has used - the decision in the package, the I/O in the agent:

- **`PinPolicy` + `PinMarkerSet`** - section 7.1.1's whole algebra: the effective state from
  the nearest marker at or above a path, the five situations, and `plan(_:at:)`, which
  returns the *smallest* marker change that produces the asked-for effect (invariant 3),
  what it clears beneath (invariant 2) and the kept state that results. Byte-wise paths
  throughout, because a server name need not be UTF-8.
- **`EvictionPlan`** - last use, the TTL comparison, the four skips (`never`, directory,
  local-only, kept) and the cache totals `status` prints.

The agent gained **`CacheEvictor`** (one actor per location: section 6.6's timer, the pass,
`evict <path>`, `evict --all`), **`LocationRuntime+Pinning`** (the marker write, the
descendant rewrite, the root-set bookkeeping, `pins`, the sweep's prune list and section
7.2's re-assert net) and **`ReplicaAccess`**, which is milestone 1's `SpikeHooks` promoted:
`evictItem` with and without the doubling backoff, `getUserVisibleURL`, the `lstat`, and the
replica lookup S6 found a pin cannot do without. `SpikeHooks` now forwards to it, so the
spike hooks and the product make the same calls.

The extension gained `NSFileProviderCustomAction.performAction`, which forwards to the
agent, and `NSFileProviderItemDecorating.decorations`. The appex's Info.plist gained
`NSFileProviderDecorations`. `IndexWriter` gained `pinMarkerRows()` and `items(under:)` -
the second a byte range rather than a `LIKE`, since paths are blobs. `RowBuilder` now derives
`kept` from the parent row's effective state, which is the whole of "descendants the index
has never seen need nothing".

### The mount proofs

Every scenario from `milestone-7-8.md`, in one line each:

| # | Scenario | Result |
|---|---|---|
| 1 | a 30 s TTL evicts a file fetched 35 s ago and not one saved since | **pass** - `stale.txt` dataless, `fresh.txt` untouched |
| 2 | the five-minute timer fires with no CLI at all | **pass** - 11 rows to 8 at 01:05:36, five minutes after the loop started |
| 3 | a pending edit is never evicted | **pass** - refused -2008, logged, passed over; the other file in the same pass went |
| 4 | `evict --all` empties the materialized set | **pass** - 9 items to 0 from one call on `.rootContainer` |
| 5 | `pin` on a folder nothing has opened downloads the subtree | **pass** - 6 files in ~60 s, including the never-enumerated `keep/sub` |
| 5a | `pin` on a path with no rows at all, ancestors included | **pass** - ancestors listed, replica looked up, both files down |
| 6 | a new server file under a pin is fetched | **pass** - inside a minute, and its row was born kept |
| 7 | `unpin` of a child leaves it lazy and the TTL takes it | **pass** - 1 dropped, 8 kept skipped; still dataless a minute later |
| 8 | `pins` lists them, and `--export`/`--import` round-trip | **pass** |
| 9 | `pin /` downloads the whole location | **pass** - 13 files, 21 rows, ~75 s, and invariant 2 cleared the nested markers |
| 10 | the Finder actions on a file and on the window background | **pass** - both toggle the pin; the pair follows `userInfo.kept` |
| 11 | the badge | **pass** - drawn, but not where the header implies (below) |
| 12 | `unpin` then the TTL takes the subtree | **pass** - 13 files dropped, the 8 directory rows left |
| 13 | `set cache-ttl` and section 8.1's Cache and Pins lines | **pass** |

### The assumption that failed: atime

Section 7 had the eviction loop take `last use = max(atime, mtime, last_fetch)`, on S4's
finding that atime follows the `relatime` rule and so "adds nothing for a materialized
file". Milestone 7's timer proof failed on exactly that clause: the automatic pass ran at
the right moment, considered the right ten items, and evicted **nothing**, because two files
fetched 280 s earlier under a 60 s TTL had an atime **23 s old**.

Chasing it produced two measurements S4's forty-second window could not have seen:

- **The atime write is deferred.** A `stat` immediately after a materialization still shows
  the old value; the new one appears a minute or so later. S4's "ten reads moved nothing"
  was measured inside that window.
- **Something advances a materialized file's atime minutes after the fetch,** with no read
  of ours anywhere near it. It is not our `lstat` (which does not move atime) and it is not
  the materialized enumerator (two enumerations in a row moved nothing); on the evidence it
  is the domain's own indexer, which S4 already saw once as "one unexplained advance".

So with atime in the `max` the TTL silently meant "time since whatever last touched the
replica", which is neither what section 7 promises nor anything a user can observe or
predict - and on a Mac with Spotlight running it would hold the whole cache open
indefinitely. **atime is now read, logged beside the age the decision used, and decided on
by nobody**; `last_fetch` and the later of the two mtimes are the whole rule, which is what
section 7 says the TTL *means*. Section 7 and a 2026-09-05 §13 entry say so; the unit test
`testAFreshAtimeDoesNotSaveAStaleFile` pins it.

The replica's mtime is now consulted beside the row's, the later winning: a save in the
mount moves the replica's before the upload finishes and the row's only afterwards.

### Two smaller things that were not as written

- **`evict --all` is one call on the root container only while nothing is *or has just
  been* pinned.** With a pin in place that call meets a kept child and fails as a whole -
  and straight after `--unpin-all` it fails too, as `NSCocoaErrorDomain` "The file couldn't
  be opened", which names no reason: the system has not yet re-read the rows whose policy
  the unpin just changed. Measured with `debug evict` in a loop: a single file becomes
  evictable **5-10 s** after the unpin, and the root container did not within a minute. So
  both cases walk the materialized set and evict the unkept files one at a time, each with
  section 5.5's doubling backoff, and a refused root container is reported and the walk runs
  anyway - the one call is an optimisation, not the contract. The cost is that the directory
  rows stay materialized, since the loop is per file. Section 7 step 4 and §13 now say so.
- **A decoration's Info.plist keys are the bare four** - `Identifier`, `BadgeImageType`,
  `Label`, `Category` - from `NSFileProviderItemDecoration.h`, not
  `NSFileProviderDecoration`-prefixed spellings and not the `NSExtensionFileProviderAction*`
  shape the actions beside them use. `BadgeImageType` is a **UTI conforming to
  `com.apple.icon-decoration.badge`**, not an asset name; the system ships `.badge.pinned`,
  `.checkmark`, `.locked`, `.syncing`, `.warning` and a dozen more in `CoreTypes.bundle`, so
  ours needs no icon asset and no exported type. Every one of those mistakes is silent, like
  `fileproviderItems` before it.

### What Finder draws for a kept item

`Category: Badge` is documented as "on top of the icon". In list view on 26.4 it is drawn as
an **orange disc with a white push-pin at the trailing edge of the Name column**, beside the
date, not on the icon. Every kept row carries it, including rows that merely inherit the
pin; an excluded folder inside a kept one carries none, which is the `kept`-not-marker rule
being visible for once.

The two custom entries behave exactly as S6 recorded on 2026-09-04, now with handlers
behind them: at the very bottom of the contextual menu, at the top level, one of the pair at
a time, and on the window background acting on the folder being shown. `Remove Download` is
still offered on a kept item and still fails.

### Driving Finder from a terminal, two additions to the recipe

The CoreGraphics right-click of 2026-09-04 still works. Two things have changed or are new:

- **The file list is `outline 1 of scroll area 1 of splitter group 1 of splitter group 1 of
  window 1`.** `splitter group 1` alone is the sidebar, which is what the older recipe
  addressed. A row's name is now `value of text field 1 of UI element 1 of the row`; it read
  `missing value` in September, so rows can be matched by name again.
- **A menu entry can be invoked without reading the menu.** Ours is always the last item, so
  `key code 126` (up, which wraps to the bottom) then `key code 36` (return) picks it. The
  contextual menu is still not readable through AX, so the screenshots are still how the
  labels are confirmed.

### The one hook these milestones added

`sshdrive debug ttl <name> --seconds N`, the cache TTL in seconds for this agent process
only. Section 7's shortest real value is `15m`. It changes the number the rule is applied to
and nothing else; `--off` restores the location's own setting. Same bargain as
`debug watch --clock-skew`.

### What stayed dormant

Section 7.2's re-assert net. It fires when a kept file turns dataless without our handler
having run, and there is no route to make that happen on 26.4: Finder's "Remove Download" on
a kept item is refused by the eager policy, and so is `evictItem` from the agent. The code
is written, counts only files the agent has *seen* materialized in an earlier pass, and
`status` carries the number if it ever does fire.

### Noticed in passing, and not milestone 7 or 8's to fix

**`sshdrive agent stop` leaves a location's `ssh -N` master running.** The agent exits
cleanly 0.2 s after the reply and never shuts its masters down, and the next start's orphan
sweep deletes the stale *socket* (section 6.1) but has no pid to kill: the old `ssh` then
holds a connection open for ever with a socket that no longer exists. Four install cycles
during this pass left one behind, and `pgrep -f "ssh -N -o ControlMaster"` is how it was
found. `remove` does drop the runtime and does shut its transport down, so this is only the
`agent stop` path. Worth a milestone 9/10 fix: either shut the gates down before exiting, or
have the sweep kill the process that owns each orphaned socket rather than only unlinking
it.

### State the VM was left in

No locations, no File Provider domains, no `~/Library/CloudStorage` entries, no `ssh`
masters (one orphan from the install cycles above was killed by hand) and no `sshdrive-*`
files in `$TMPDIR`; `~/m78` and `~/m78b` removed from `deb`, `~/m78-tools` and `~/m78-shots`
removed from the VM. `sshdrive doctor` is green apart from the expected uninstall note. The
signed Debug build is installed at `/Applications/SSH Drive.app` and the agent is running.

---

## 2026-09-04 (milestone 6) - S7: the root set, the sweep, the fallback ladder and the mass-deletion guard

Milestone 6 end to end: DESIGN.md section 6.5's root set with its rotation and the `viewed`
reason, section 5.3's anchors and catch-up sweep, section 6.4's poll cadence, tier 0, tier 1
and the fallback ladder, the mass-deletion guard and `sshdrive accept-deletions`, and
section 5.3's reconcile against the replica, which milestone 5 left owed. Same headless VM
(macOS 26.4.1 arm64, Xcode 26.4, `OpenSSH_10.2p1`), the signed Debug build installed over
`/Applications/SSH Drive.app` with `ditto`. Testbed up on the Mac. Steps are in
`milestone-6.md`.

**Tier 2 is not here.** The helper is milestone 9, so `auto` tops out at sweep, S7's
helper questions (the NDJSON stream beside two SFTP channels, FreeBSD kqueue on a
100,000-file tree) are out of scope, and every location with a shell shows
`◐ change detection  sweep` with a `note:` saying the helper is not in this release.

**503 package tests, 0 failures** (was 381; 39 skipped without the testbed). The 122 new
ones are `RootSetTests`, `SweepPlanTests` (which also holds `SweepWindowTests`),
`SweepParserTests`, `ChangeDetectionLadderTests`, `MassDeletionGuardTests`,
`PollScheduleTests`, `RootsAndHeldTests` and eight testbed-backed `TestbedSweepTests`.

### What was built

`AgentCore` took the whole of section 6.4's decision-making, because every part of it that
is worth testing is a decision and not an I/O - the same split milestone 5 made for the
breaker:

- **`RootSet`** - section 6.5's three reasons, the 64-per-cycle `materialized` rotation in
  order of least recent listing, `ceil(M / 64)` as the rotation period, the 256-entry
  `viewed` cap with its LRU eviction, the pin-root exclusion, and the shallow/recursive
  split tier 1 needs. Byte-level containment throughout: a root name need not be UTF-8.
- **`SweepPlan`** - the two `find` invocations, batched at 64 KB of argv, `-cmin` with the
  `-mmin` fallback, GNU `-printf`, the `-path <glob> -prune` escaping, and a POSIX `sh`
  body that hands `find` one batch at a time out of a single `set --` list. Nothing from
  the user is ever in the body.
- **`SweepParser`**, **`SweepWindow`** (the server-clock window, `ceil(delta/60) + 1`, and a
  clamp with a `clockWentBackwards` flag when the stored stamp is in the future),
  **`RemoteSweep`** (one sweep on one exec channel under section 6.4's heartbeat wrapper,
  ended by its own closing sentinel), **`ChangeDetectionLadder`**, **`MassDeletionGuard`**
  and **`PollSchedule`**.

The agent gained **`ChangeDetector`**, one actor per location holding the cadence and the
tier. It is deliberately not part of `LocationRuntime`: the runtime is the index's writer
and everything on it serialises behind the index, so a detector that lived there would put
a multi-second sweep in front of every `item(for:)` fallback and every fetch. Beside it,
**`ReplicaEnumerators`** (the system's own `enumeratorForMaterializedItems()` and
`enumeratorForPendingItems()`, which only an unsandboxed process can usefully drive),
**`LocationRuntime+ChangeDetection`** (the guard-aware listing diff, the `held` table,
`accept-deletions`, the root-set refresh, the tier 0 cycle and the sweep's application to
the index), **`IndexReconcile`** and **`ExtensionPeers`**.

The index went to **schema version 3**: `roots.last_listed` (the rotation's round-robin
key, distinct from `last_seen`, which is the `viewed` LRU key), `held.checks` and
`held.reason`, and three `meta` keys - the sweep's server clock, the last full sweep and
the tier in use. The migration is an explicit `ALTER TABLE` after a `PRAGMA table_info`,
because `CREATE TABLE IF NOT EXISTS` does not alter an existing table; `RootsAndHeldTests`
builds a version 2 database by hand and migrates it.

### S7, question by question

| # | Question | Answer |
|---|---|---|
| s7-1 | Does tier 1 coexist with two SFTP channels on one connection? | **Yes**, and it is not close: a 15,000-file sweep is 0.5 s of channel time |
| s7-2 | How long does the `-cmin` sweep take on a 1M-file tree with 200 roots? | **876 ms** for the incremental case; 175-376 ms for 200 roots |
| s7-3 | `-cmin` / `-printf` across GNU and busybox, and the `-mmin` fallback | busybox has **neither**; the fallback provably misses a `chmod` |
| s7-4 | The server-clock window against skew | **Cannot be tested honestly here**; the reference is skewed by a hook and said so |
| s7-5 | `sh -s` under bash, zsh, fish, tcsh, dash, and `bashbg` | All pass, including a whole **sweep** ending on the closing sentinel |
| s7-6 | Abrupt client kill: does a bare background process survive? | **Yes, on every server - `ClientAliveInterval` set or not** |
| s7-7 | External `sftp-server` behind a noisy shell; `ForceCommand internal-sftp` | Both as section 9.2 says |
| s7-8 | A tier 0 cycle with as many `materialized`-only roots as we can make | See below |

#### s7-1. Tier 1 beside two SFTP channels

`TestbedSweepTests.testSweepCoexistsWithTwoSFTPChannelsOnOneConnection`: one `-N` master,
two `SFTPChannel`s each with a real wire client `readdir`ing in a loop, and a sweep of
`deb`'s 15,011-file `data/` tree on an exec channel at the same time. All three channels
lived, both listings kept being served through the sweep, both channels answered an `lstat`
afterwards, and the master was untouched. The whole test is **0.54 s**, which is the more
useful half of the answer: a sweep is not a long-running stream, it is half a second of
channel time, so on a `MaxSessions 2` server it competes with the probe and with nothing
else.

#### s7-2. The sweep on a million files

The README's scaling knobs need the `deb` service recreated from the Mac, which this
session could not do without re-seeding the `data/` tree every other spike uses. So the big
tree was seeded beside it over ssh: **2,000 directories x 500 empty files = 1,000,000
files, in 11 seconds.**

| Shape (GNU findutils, Debian 12, warm) | Time | Output |
|---|---|---|
| 200 roots, recursive, `-cmin -60 -printf` (everything matches) | 175-376 ms | 7,213,200 B |
| 200 roots, `-maxdepth 1`, same | 174-181 ms | the same set |
| 1M tree, `-cmin -60 -printf` (everything matches) | 1,673-2,946 ms | 72,132,061 B |
| 1M tree, `-cmin -1` (nothing matches) | 858-886 ms | 0 B |
| **1M tree, `-cmin -2` after one `touch`** | **876 ms** | one record |
| 1M tree, unbounded + `-printf` (a GNU full sweep) | 1,635-3,001 ms | 72,132,061 B |
| 1M tree, unbounded + `-print0` (a non-GNU full sweep) | 204-228 ms | 23,028,008 B |

**The number to remember is 876 ms**: an ordinary incremental sweep of a million-file tree,
returning the one file that changed. The second number is why: `-cmin` and `-printf` each
force a `stat` per entry, so the same walk is 204 ms with neither and 850-1,650 ms with
either. That is a floor, not a NAS - a container on the same Mac cannot have its page cache
dropped - but it settles the question section 6.4 asks, which is whether one command per
minute is affordable at all. It is, by a wide margin.

The 64 KB argv batching is right but rarely load-bearing: 200 roots is 2,799 bytes and
2,000 roots is 28,000, so a single batch carries about 4,600 roots at these name lengths.
`SweepPlanTests` proves the batching; the tree proves it is not the constraint.

#### s7-3. GNU against busybox

BusyBox v1.36.1, identical on `alp` (2206) and `alp-nocmin` (2208):

```
find data -maxdepth 0 -cmin -60   ->  find: unrecognized: -cmin      rc=1
find data -maxdepth 0 -printf '%p' ->  find: unrecognized: -printf   rc=1
find data -maxdepth 0 -mmin -60   ->  rc=0
find data -maxdepth 0 -newer FILE ->  rc=0
```

Two things follow that were not in the design. **`find --version` prints
`find: unrecognized: --version` and exits 0**, so a flavour probe keyed on the exit status
would call every busybox server GNU and every sweep on it would fail outright with nothing
on stdout; ours reads the `busybox` banner and the `-cmin` answer, and `SweepPlan` refuses
`-cmin`/`-printf` on a busybox flavour a second time even when the probe claims them. And
`alp-nocmin`'s shim is indistinguishable from stock busybox, so it is not a separate case -
`testbed/README.md` already said so and now says why it matters.

**The cost of the fallback, measured.** A file whose mtime was set back to 2020 and then
`chmod`ed:

```
after create, -mmin -1 hits: 1
after chmod with an old mtime, -mmin -1 hits: 0
```

and on GNU `deb` the same probe is found by `-cmin` and missed by `-mmin`
(`TestbedSweepTests.testCminCatchesAChmodThatMminMisses`). So section 6.4's claim is exact:
the fallback loses ctime-only changes and nothing else, and `status` says so on every
busybox location as an ordinary line.

#### s7-4. The server clock, and what could not be tested

**A container cannot have its clock skewed.** Docker has no time namespace and every
container shares the host's clock; skewing the VM instead would move the Mac's clock, which
is the one thing the window must not depend on. So this is recorded as **not answered by a
real skew**, and what was built instead is said plainly: `sshdrive debug watch
--clock-skew N` shifts the *stored server timestamp* the next window is computed from, and
`status` prints `note: the sweep's server-clock reference is shifted by Ns by a debug hook`
while it is set.

Building it did find a real error in the first implementation, though, and it is the error
section 6.4 warns about. The window was computed as `serverNow - stored` with `serverNow`
taken from the **Mac's** wall clock - which folds the entire clock difference into the
window, so a server five minutes behind would be swept with a window of nothing at all.
The window is now **elapsed time on our clock applied to the server's stamp**: the local
time at which the server stamp was stored is kept beside it, and `N` is
`ceil((now - thatLocalTime) / 60) + 1`. Neither clock's absolute value enters into it,
which is what section 6.4 means and what a skewed server would otherwise break.

The other half of the rule is enforced where it belongs: `RemoteSweep` returns
`serverTime: nil` for a sweep whose closing sentinel never arrived, and `ChangeDetector`
stores nothing in that case, so a cut-off sweep leaves the next window covering everything
it missed.

#### s7-5, s7-7. The shells, and the two awkward accounts

All the milestone 2 answers hold, and tier 1 adds two of its own: a whole **sweep** returns
on its closing sentinel against `bashbg`, whose rc file leaves a background child holding
stdout so EOF never arrives, and six directory names from the testbed's `weird/` tree -
`$(echo pwned)`, `quote'name`, `space in name`, `*star*`, `[bracket]`, `back\slash` - are
used as **sweep roots**, each returning its own `inside.txt` and creating no `pwned` file.
`forcesftp` is still reported as "no shell access (ForceCommand)", and `deb-extsftp`'s
`extnoisy` still needs the exec-channel `sftp-server` fallback.

#### s7-6. The bare background process

This is the one where the design was optimistic. The control case - a bare `sleep &`
started **by the session that is then `SIGKILL`ed**, with no wrapper:

| Server | `ClientAliveInterval` | at t+180 s |
|---|---|---|
| `deb-shells` (2202) | unset | **alive** |
| `deb` (2201) | 15 / 3 | **alive** |
| `alp` (2206, busybox) | unset | **alive** |

Section 6.4 explained the danger in terms of `ClientAliveInterval` being unset, which reads
as though setting it would fix the problem. It does not: sshd reaping the session does not
reach a child that has left the foreground job. The section now says so. The heartbeat
wrapper is not a workaround for a common misconfiguration; on every server measured it is
the only thing that ever kills what we started, and `TestbedHeartbeatTests` shows it doing
so within 75 s under dash's watchdog branch, busybox's `read -t` branch, a dash login
shell, and on silence alone with the channel still open.

#### s7-8. A tier 0 cycle with 5,000 `materialized`-only roots

Five thousand directories on `deb`, a location on them, the root enumerated so every
directory has a row, and the `materialized` reason put on all five thousand with
`sshdrive debug roots --seed 5000`. Only the *reason* is injected; every one of those
directories exists and is really `readdir`ed.

| | Directories listed | Time |
|---|---|---|
| one tier 0 cycle under the rotation | **65** (64 materialized-only, plus the root, which is `viewed`) | **0.91 s** |
| one **full** cycle, rotation suspended | **5,001** | **16.69 s** |

`rotationPeriod` is 79 = `ceil(5000 / 64)`, and `status` prints
`5001 root(s) rotating over 79 cycles`. The rotation is worth about **eighteen times** here:
without it a location holding five thousand cached directories would spend 16.7 s of every
60 s listing them. That is section 6.5's argument, measured.

### The mount proofs

Two locations, `m6` on `deb` (GNU `-cmin -printf`) and `m6a` on `alp` (busybox `-mmin`).
Every change is made by a **separate** ssh, never by the agent.

**A file created, modified, renamed and deleted on the server, seen in the mount:**

| Step | `m6` (GNU) | `m6a` (busybox) |
|---|---|---|
| `created.txt` appears | 59,743 ms | 60,687 ms |
| its content changes | 104 ms | 117 ms |
| `renamed.txt` appears | 59,923 ms | 59,406 ms |
| `created.txt` vanishes | 7 ms | 4 ms |
| `renamed.txt` vanishes | 59,647 ms | 60,122 ms |

Every step inside one poll interval on both. The pattern is the cadence rather than the
mechanism: a change is found by the next 60-second cycle and everything that cycle finds
arrives together, which is why the second and fourth rows are milliseconds. The busybox
column matches because a create, a write, a rename and a delete all move mtime; the one
thing `-mmin` misses is a ctime-only change.

**A directory deleted on the server with a pending local edit inside it:**

```
pending set: keepme/note.txt                       (count 1)
the directory is deleted on the server
  "deleted" : 0,  "held" : 1
held: path "keepme"   reason "1 deletion held in the location root"
still in the mount? yes          the local edit: edited-on-the-mac
status: 1 deletion(s) held in the location root, re-check at 23:44
        apply them now with: sshdrive accept-deletions m6
accept-deletions -> Applied 1 held deletion(s).   still in the mount? NO
```

Note what is held: the **directory**, while the pending edit is on the file inside it. A
listing infers the deletion of the directory, not of the file, so the guard counts every
ancestor of a pending path as pending too. Matching pending paths exactly - which the first
implementation did - would have let `keepme` through and stranded the save inside it, which
is exactly the case S5 measured. Found by the mount proof, fixed, and covered by
`MassDeletionGuardTests`.

**A mass deletion over the threshold:** 40 files, 30 removed in one go.

```
rows before: 40      ->  "deleted" : 0,  "held" : 30      in the mount: still 40
a file still on the server:  f31.txt -> x
a HELD file:                 cat .../bulk/f01.txt: Operation timed out
status: 30 deletion(s) held in bulk, re-check at 23:45
accept-deletions m6 bulk -> Applied 30.   in the mount: 10
```

`Operation timed out` is `ETIMEDOUT`, which is `.cannotSynchronize`; `.noSuchItem` would
have given `ESTALE` (S5). Section 6.4 asks for exactly that - the item stays and the user is
told the truth about it.

**`status`** shows the tier, the cadence and whether the domain is active, the cycle count,
the root count with the rotation period when it exceeds one cycle, the last cycle or full
sweep with what it found and how long it took, the ladder's note, the `-mmin` warning on a
busybox server, and the held-deletion line with the command that applies it.

### Four assumptions that failed

**Section 6.4 framed the lifetime problem around `ClientAliveInterval`.** It is not a
`ClientAliveInterval` problem: a bare background child survives an abrupt client kill on
every server measured, with the setting on or off. The section now says the wrapper is the
only mechanism there is, and section 13 records it.

**Section 5.3's working-set enumerator could report an empty change set, and that loses
changes.** The extension answered `finishEnumeratingChanges(upTo: theSameAnchor)` whenever
its reader was not yet usable. Since the system launches a **fresh extension instance for
every working-set signal** (S5 measured that for writes; it is true for signals too), the
first `enumerateChanges` on a signalled instance races the `indexReady` round trip, and an
empty change set at the anchor the system already holds tells it that it is up to date. The
symptom on a real mount was a file deleted on the server and removed from the index that
stayed in Finder for ten minutes, until an unrelated change signalled again and the system
caught up on both at once. The answer is `.serverUnreachable`, which the system retries.
Found by the milestone 6 mount proof and fixed; section 5.3 and section 13 record it.

**Section 6.4's server-clock window is only skew-proof if it is written as elapsed time.**
The first implementation computed `N` from the **Mac's** wall clock minus the stored
**server** stamp, which folds the whole clock difference into the window - a server five
minutes behind would have been swept with no window at all, which is exactly the failure
the rule exists to prevent. The agent now keeps its own clock reading beside the server
stamp and computes `N` from the elapsed time between them, so neither clock's absolute
value enters into it.

**A sweep root is not always expressible.** Section 9.2's `set --` pipeline is Strings end
to end, and section 5.4 says server names need not be valid UTF-8, so a root whose bytes are
not UTF-8 cannot reach `find` at all. Such a root is dropped from the sweep's argv and
listed at tier 0 in the same cycle instead, which watches it at the same cadence and loses
only the server-side walk. Section 6.4 now says so, and so does section 13.

### Three smaller things

- **`find` has no portable `--`**, so every sweep root is spelled `./name`. A top-level
  directory called `-name` would otherwise be read as an option and take the whole sweep
  with it. The prefix comes back on every path and is stripped before the path reaches the
  `RelativePath` constructor.
- **`rewritePaths` moved `held.path` and not `held.dir`.** The guard's 5- and 30-minute
  re-checks are driven by re-listing the directory the deletion was inferred from, so a
  `dir` left at the old name would be re-listed for ever against a path that no longer
  exists and the holds would never resolve. Found by reading, not by a test, and fixed with
  a test.
- **The orphan control-socket sweep matched by name alone, and `$TMPDIR` is shared.**
  `sshdrive doctor` on a clean VM reported `[ fail ] control sockets  6 socket(s), 6 with
  no location` - all six were `sshdrive-nested-<uuid>.sqlite-wal` and `-shm`, sidecars of
  the package's own temporary test databases. The sweep would have deleted them, and on a
  worse day it would delete whatever else in a shared directory happened to start with
  `sshdrive-`. It now `lstat`s each candidate and takes only `S_IFSOCK`, following no
  links.
- **A CLI command naming a location is a touch, and it has to be.** Section 6.4 says so and
  it was easy to read as decoration - until the first mount proof, where `test -e` inside
  the mount is answered from the system's replica and never reaches the extension (a folder
  is enumerated once, ever), so a run that only polled the mount fell to the ten-minute
  cadence half way through and the last three steps timed out. A person watching a mount
  from a terminal produces no File Provider traffic at all; the CLI is the only signal
  there is.
### State the VM was left in

No locations, no File Provider domains, no `~/Library/CloudStorage` entries, no
`sshdrive-*` control sockets and no `ssh` masters; `~/m6`, `~/m6a`, `~/m6roots` and the
million-file `~/bigtree` removed from the servers, and `sshdrive doctor` green apart from
the expected uninstall note. The signed Debug build is installed at
`/Applications/SSH Drive.app` and the agent is running.

---

## 2026-09-04 (milestone 5) - S5: the breaker, reconnection, the queued-write flush, sleep/wake and the deadline re-arm

Milestone 5 end to end: DESIGN.md section 6.3's circuit breaker with its bounded waiting,
reconnection with backoff and the mux channels re-opened, the queued-write flush on
network-up, sleep and wake, the agent-missing behaviour of section 5.2, and section 4.2's
deadline re-arm. Same headless VM (macOS 26.4.1 arm64, Xcode 26.4, `OpenSSH_10.2p1`), the
signed Debug build from `scripts/mac-build.sh signed` installed over
`/Applications/SSH Drive.app` with `ditto`. Testbed up on the Mac; one server, `deb`
(2201, Debian, OpenSSH `sftp-server`), and two locations, `m5` and `m5b`. Steps are in
`milestone-5.md`.

**381 package tests, 0 failures**, four runs in a row (was 355; 31 skipped without the
testbed). The 26 new ones are `CircuitBreakerTests` (section 6.3's four rules against an injected clock and an
injected jitter: the 2 s doubling to 60 s, the 300 s key-agent cap, the half-open probe,
the bound on a waiting call being the attempt's own remaining 60 s and not 60 s from now,
the stop on auth and host-key failures surviving a reset, and only a deadline stop being
re-armable) and `DeadlineRearmTests` (section 4.2: each trigger firing exactly once per
stop, idle over 30 s and a locked screen not firing the request trigger, the presence
reading taken at most once a minute proven by counting it, an unlock consulting presence
not at all, and refusals never being re-armed), plus one in `LocalAttributesTests` for the encoding bug
below.

### What was built

`AgentCore` gained two pure state machines, because everything in this milestone that is
worth testing is a decision and not an I/O: **`CircuitBreaker`**, a struct that takes the
time as an argument and answers `proceed` / `connect` / `wait(seconds:)` /
`failFast(reason:)`, and **`DeadlineRearmState`**, which owns section 4.2's two triggers
and the once-a-minute presence rule. The agent side is
**`ReconnectingTransport`** plus its `ConnectionGate` actor: an `SFTPTransport` that holds
the live `SSHBackedTransport` - or does not - so nothing in `LocationRuntime` changed
except that its transport can now be absent. Beside them, `PowerEvents`
(`IORegisterForSystemPower`, not `NSWorkspace`: the agent runs no `NSApplication`),
`NetworkPathGate` (`NWPathMonitor`), `AgentPresence` (`CGEventSource` +
`CGSessionCopyCurrentDictionary`) and `ScreenLockObserver`
(`com.apple.screenIsUnlocked`).

`LocationRuntime.start()` was split: everything that can only be known from a live
connection - the identity behind section 5.4's mapping, the channel budget, both spellings
of the root, the root row - moved into `applyConnection()`, which `start()` calls and
tolerates the failure of, and which the gate calls again on **every** reconnect. That is
what makes a location whose server is down still mount, still serve the replica and still
queue writes, instead of failing `start()` and getting no domain at all.

### The instrument this spike needed

`sshdrive debug calls <name>` is a ring of the last 2,000 File Provider calls with the
arrival time, the outcome and the gap since the previous call of the same method for the
same item. Every "how long does the system wait before calling again" question below is
read off it, and none of them can be answered from `os_log` or `fileproviderctl`, which
report state rather than traffic.

### S5, question by question

| # | Question | Answer |
|---|---|---|
| s5-1 | How long does the system retry a write after `.serverUnreachable`? | **For ever, on a doubling backoff, and it grows without a cap in sight** |
| s5-2 | Does `signalErrorResolved` wake the flush? Does `signalEnumerator` alone? | **Yes, in 20 ms. And no - nor does reconnecting** |
| s5-3 | Do requests still reach the extension while the domain is connected and every call fails fast? | **Yes**, and the domain stays connected through a deadline stop |
| s5-4 | How long does the system wait after `.serverUnreachable` from `fetchContents` before calling again? | **It never calls again.** There is no interval to measure |
| s5-5 | What does the extension see when the mach service is gone, and can it call `disconnect(reason:)`? | **It can, and does.** The domain goes permanently disconnected; the replica and queued writes survive |
| s5-6 | Does the system time out an `enumerateItems` held the full 60 s? | **No.** 60.19 s, answer taken, extension untouched |
| s5-7 | A pending edit when the item is reported deleted? And with an unmatched content version? | **Re-offered as a `createItem`,** which then collides for ever |
| s5-8 | `.noSuchItem` versus `.cannotSynchronize` from `fetchContents`? | `ESTALE` versus `ETIMEDOUT`; **neither removes the item** |
| s5-9 | Is a `readdir`/`lstat` walk served from the replica while every enumeration fails? | **Yes**, and it reaches the extension not at all |

#### s5-1. The write retry, measured

`debug fault --unreachable on`, one edit in the mount, twelve minutes of watching. Every
gap is the arrival of the next `modifyItem` for the same item:

```
5.50 s -> 10.56 -> 20.30 -> 43.03 -> 79.36 -> 153.23 -> 331.30
```

Roughly a doubling, and 331 s is five and a half minutes ten minutes into the outage with
no sign of a ceiling. **Each retry arrives on a freshly launched extension instance** - an
`indexReady` lands in the same millisecond as every `modifyItem` - so the system is not
holding an instance open for the pending work; it relaunches to make each attempt.

That number is the whole argument for the two things the agent now does that section 6.3
did not previously spell out: it reconnects on the breaker's backoff without being asked,
and it retries a read that met a dead connection once. Left to the system, a mount whose
server blinked comes back somewhere between three and eleven minutes later, and only if
there was a pending write at all.

#### s5-2. Which signal does it

The recovery normally sends `signalErrorResolved` and then `signalEnumerator`, so
`debug breaker --quiet-recovery on` was added to send neither and let each be sent by hand.
With a write pending and the backoff out past five minutes:

| Step | Result |
|---|---|
| the location reconnects, no signal sent | 75 s, nothing |
| `signalEnumerator(.workingSet)` alone | 60 s, nothing |
| `signalErrorResolved(.serverUnreachable)` | `modifyItem` at **+20 ms**, upload done, pending set empty |

So section 5.6's "`signalEnumerator` alone is the fallback" is wrong and is now corrected:
there is no fallback. The working-set signal is still sent, because the working set needs
it, but it is not what flushes anything.

#### s5-3, s5-9. What still reaches us, and what the replica serves

With every call failing fast, `ls -R` of the mount returns the whole tree with exit 0 and
`stat` of a dataless file answers, and **neither reaches the extension at all**: a folder
is enumerated once, ever (section 6.5), so the walk is the system's replica answering. That
is exactly what section 5.3's reconcile stall needs.

What does reach us is the work that needs the server. During one deadline stop, with the
breaker refusing everything, the journal recorded 6 `fetchContents` and 4 `createItem`
arrivals and `failFastCalls: 7`, while `fileproviderctl dump` showed the domain **not**
disconnected - no `permanently disconnected` marker, unlike the agent-missing case below.
Section 4.2's present-user re-arm has traffic to ride on.

#### s5-4. The fetch retry that does not exist

A `cat` of an evicted file with the location down produces exactly one `fetchContents`, one
`.serverUnreachable`, and `cat: …: Operation timed out` **at once**. Seven minutes of
watching produced no second call. A second `cat` produces a second call, so the item is not
poisoned - the system simply has no retry of its own for a fetch, and no spinner either
when the answer is immediate.

The question as section 11 asks it ("how long the system waits … since that, not our
breaker, bounds the spinner") therefore has a false premise. **Our breaker is the only
thing that bounds anything here**, and the spinner exists only while a call is waiting for
a connect attempt, which is s5-13 below.

#### s5-5. The agent's mach service gone

`sshdrive agent stop`, then `SSHDRIVE_AGENT_ROLE=unregister` on the app's main executable,
which is the only thing that clears launchd's record (S1(f)). `launchctl print` then says
`Could not find service "org.shirls.sshdrive.agent"`.

**`disconnect(reason:)` works from inside the extension.** `fileproviderctl dump` shows

```
domain: 4{34}E (m5)
  + (⏹  permanently disconnected)
  can't dump the extension: Error Domain=NSFileProviderErrorDomain Code=-1004 …
      UserInfo={NSFileProviderErrorDomainDisconnectionStateKey=4}
```

and the item-level state carries `error:'NSError: FP -1004 …' domain:serverUnreachable`.
So section 5.2's message can be shown to the user by the extension, and does not have to
live only in `sshdrive doctor`.

What still works with no agent at all: the directory listing (replica), and a **write** -
`echo agent-gone > …/newfile.txt` succeeded locally and was queued. What does not: any
fetch, which is `ETIMEDOUT`. `open -g -a "SSH Drive"` brought the agent back, the
disconnect was lifted, and `newfile.txt` was on the server with its contents.

#### s5-6. Sixty seconds inside `enumerateItems`

A second location, `m5b`, added and then never listed, with `debug fault --transport-hang
60000` set before the first `ls`:

```
12:01:43.053  enumerateItems  arrived
12:02:43.240  enumerateItems  60186.8 ms   2 item(s)
ls exit=0 after 61s
```

The system waited, took the answer, and the extension process was still alive afterwards.
Section 6.3's bounded wait can use the whole 60 s of the authentication deadline without
the system taking the call away.

#### s5-7. A pending edit whose item is reported gone

`debug row <name> <path> --forget` deletes the row and its subtree with a deletion anchor -
what the extension reports when a listing says the item has gone (section 5.3, no
tombstones) - and touches nothing on the server. With an edit pending:

- the file stays in the mount with the **local** content, and stays in the pending set;
- the pending `modifyItem` becomes a **`createItem`**, re-offering the same bytes as a new
  item;
- that create is answered `.filenameCollision`, because the path is still on the server;
- and the system retries a collided create for ever with no alert (section 5.5, S3).
  Observed at 11:51:54 and again at 11:57:21, four hundred seconds apart, still going.

So no data is lost, and nothing is ever resolved either: the mount shows the new content,
the server keeps the old, and the user is told nothing. That settles the question section
11 attaches to this row - **the mass-deletion guard must hold deletions of pending items** -
and adds a second reason: the item comes back with a new identifier, so a pin or a tag on
it is lost even when the create does succeed.

The unmatched-content-version half could not be measured separately here, because the
row was already forgotten by the first half and `debug row --content-version` needs a row;
it is left in the runbook for the next pass. What it would add is small: the identifier
does not change, so the create-versus-modify finding above does not apply to it.

#### s5-8. The two fetch errors

| Fault | What the reader gets | The item |
|---|---|---|
| `.cannotSynchronize` | `Operation timed out` (`ETIMEDOUT`) | still listed |
| `.noSuchItem` | `Stale NFS file handle` (`ESTALE`) | still listed, after 60 s and after a working-set signal |

**Neither removes the item.** The rule that `.noSuchItem` deletes the user's file is about
`item(for:)` (section 5.2), not about `fetchContents`, and the mass-deletion guard's
preference for `.cannotSynchronize` therefore rests on the message the user sees rather
than on a deletion that does not happen. Both were reversible: clearing the fault and
re-reading returned the content.

### The two proofs on a real mount

**An edit made while the master is dead is flushed after reconnect.** `kill -9` on the
master, then `echo … > edit.txt`:

```
11:37:44  write exit=0, pending count 1, server still says "before-the-outage"
          sshdrive list: mounted  offline (backing off for 4 s after 3 failure(s))
11:38:24  46 s later: pending count still 1, server unchanged
11:38:30  the server comes back
11:38:30.911  modifyItem -> modified          (20 ms after signalErrorResolved)
11:38:42  server: written-while-the-master-was-dead
```

**A fetch arriving during a reconnect resolves within the section 6.3 bound.** With
`debug fault --connect-hang 20000` (the attempt stalls, calls are left alone) and the
master killed, two reads three seconds apart:

```
waitedCalls 3, failFastCalls 0
read B  exit=0 after 21s      fetchContents 17520.7 ms   6 bytes
read A  exit=0 after 21s      fetchContents 20555.4 ms   3000000 bytes
```

Both waited for the one attempt and both succeeded, bounded by the attempt's own remaining
60 s and not by any retry of the system's - which, per s5-4, does not exist. And the first
read after a **silent** master death now succeeds in 1 s rather than failing, because a read
that meets a dead connection is retried once through the breaker (below).

**The Finder-visible spinner.** `~/m5-shots/2*.png`, captured with `screencapture -x` over
ssh. While the fetch waits for the connect, the item's status column shows a **circular
progress indicator** where the other, dataless items show the cloud-with-a-down-arrow; the
row stays selected, no alert appears, and after the fetch the badge is gone entirely. The
indicator is identical in the frames at t+5 s, t+13 s and t+21 s, so it is a static
progress ring rather than an animation, and it is the whole of what the user sees for a
21-second reconnect.

### Sleep and wake

**The VM does not honour `pmset sleepnow`:** `Unable to sleep system: error 0xe00002e2`,
exit 71. `pmset -g` reports `sleep 1 (sleep prevented by powerd)` on a `VirtualMac2,1`, and
the assertion holding it is powerd's own "Prevent sleep while display is on". So the two
handlers were driven through `sshdrive debug power will-sleep|did-wake`, which calls exactly
what the IOKit callback calls; `IORegisterForSystemPower` itself registers successfully on
this VM (`debug power` reports `registered: true`), so what is unproven is only that macOS
delivers the messages, not what the agent does with them.

| Step | Result |
|---|---|
| will-sleep | both masters gone (`-O exit`), both locations `offline (idle)`, **no** reconnect scheduled |
| did-wake | new masters within 8 s, `connected`, `reconnects` incremented |
| `NWPathMonitor` path down | `hasNetworkPath false`, state `no network path`, a read fails fast (`failFastCalls` +1) with no socket opened |
| path up | reconnected, `reconnects` incremented |

The will-sleep handler acknowledges the message with `IOAllowPowerChange` after the drop,
with a 5 s cap so a wedged `ssh` can never delay a lid close.

### The deadline re-arm

A headless VM has no key agent, no FIDO key and no screen, so the stop was produced with a
new fault, `debug fault --unreachable on --connect-failure authenticationDeadline`, which
makes the attempt fail with exactly the classification section 6.1's exit classifier would
produce, and presence was supplied through an override file.

| Step | Result |
|---|---|
| the attempt fails `authenticationDeadline` | `state: stopped: authenticationDeadline`, `rearmArmed: true`, and `sshdrive show` says "offline (stopped: authenticationDeadline)" |
| a request with input idle **45 s** | no attempt; `presenceEvaluations` +1, `rearmRequestUsed` false |
| a request 5 s later, idle now 2 s | no attempt and **no presence read at all** - the once-a-minute rule |
| a request 65 s later, idle 2 s | one attempt; `presenceEvaluations` +1 |
| the screen-unlock notification | one attempt, `state: connecting`, without reading presence at all |
| the screen locked (`locked=1`) | `userIsPresent false` |
| the domain, throughout | **not** disconnected; `fetchContents` and `createItem` kept arriving |

Each new deadline stop re-arms both triggers again, which is section 4.2 as written ("if it
times out again the location is stopped again until the next trigger"), so "exactly once"
is per stop and not per lifetime.

**`launchctl setenv` does not reach a launchd agent on macOS 26.** The first attempt at the
presence override was `SSHDRIVE_PRESENCE_OVERRIDE` in the user session's environment plus
`sshdrive agent restart`; `debug presence` kept reporting `overridden: false` and the
machine's real idle time. The override now reads
`<group container>/presence-override` first, needs no restart, and the environment spelling
is kept only for a harness that spawns the agent itself.

### Simulating an outage from inside a VM, and what is still missing

Four substitutes were used, in order of how much of the stack they exercise: `kill -9` on
the master (the connection dying), `debug breaker --drop` (the clean `-O exit` form),
`debug fault --unreachable on` (every **connect attempt** fails, so the breaker opens on the
ordinary path) and `debug fault --connect-hang MS` / `--transport-hang MS` (a stall in the
attempt, or in every call).

One correction is worth recording, because the first shape of the fault measured nothing.
`--unreachable` originally failed the transport **call**, which short-circuits `acquire()`:
the breaker was never entered, `failFastCalls` stayed at zero, and the fault was testing
itself. Failing the **attempt** instead is what makes a faulted location take exactly the
path a dead server takes.

**What a real link-down would still add,** for whoever has the host to hand. `docker
compose stop deb` in `testbed/` on the Mac gives a server that completes the TCP handshake
and then refuses, which is the only way to see the `ConnectTimeout=15` and connection-refused
branches of the exit classifier under the breaker rather than under a synthetic failure;
and taking the VM's interface down is the only way to see `NWPathMonitor` report an
unsatisfied path for real, rather than through `debug power path-down`. Neither changes any
answer above - the breaker sees the same classification either way - but both are cheap and
would close the last gap between "the fault says the attempt failed" and "the attempt
failed".

### Three assumptions that failed

**Section 5.6's fallback does not exist.** "S5 confirms `signalErrorResolved` wakes the
flush; `signalEnumerator` alone is the fallback" - the second half is false. Neither
`signalEnumerator` nor a plain reconnect wakes a queued write. Section 5.6 corrected, and
section 13 records it.

**Section 6.3 assumed the system's own retry was the thing to bound.** It is not: there is
no retry for a fetch at all, and the retry for a write has passed five minutes by the time
the mount has been down ten. The section now says the breaker's backoff is a reconnect
schedule the agent runs unprompted, and that a read which meets a silently dead connection
is retried once. Both are new behaviour in the code, not only in the doc.

**Section 6.4's question about pending items has a sharper answer than "hold them".** The
system does not lose a pending edit on an item we report deleted - it re-offers it - but it
re-offers it as a **create**, which collides with the path that is still there and is then
retried for ever with no alert. The guard has to hold, and the reason is a stranded save and
a lost identifier rather than lost bytes.

### Two smaller things

- **`CGEventType` has no `.any` in Swift.** `kCGAnyInputEventType` is a C macro for
  `0xFFFFFFFF` and does not import, so the presence read spells it
  `CGEventType(rawValue: ~0)`. Asking for one concrete type instead would miss a user who
  only moved the mouse.
- **`kIOMessageSystemWillSleep` and friends do not import either** - they are
  `iokit_common_msg(0x280)` macros. `PowerEvents` spells out `0xE0000280`, `0xE0000270` and
  `0xE0000300` with the arithmetic that produces them.
- **`scripts/mac-build.sh` rsyncs with `--delete`, and `build/` does not exist on the Linux
  side,** so every run wipes the Mac's build directory. Run `signed` last: a `test` run after
  it removes the app that was about to be installed, and `ditto` fails with "Cannot get the
  real path for source".
- **One "flaky test" was a real bug.** `RowBuilderTests.testTheSameAttributesTwiceProduceTheSameVersion`
  failed about one run in three with two different xattr hashes for the same attributes.
  The blob the metadata version hashes is `JSONEncoder().encode(LocalAttributes)`, and
  `JSONEncoder` promises no key order without `.sortedKeys` - so the same attributes encode
  to two different byte strings **inside one process**, the hash moves on its own, and the
  system re-reads every item the agent holds for nothing. `.sortedKeys` is now set and
  `LocalAttributesTests` encodes a six-key blob two hundred times and compares the bytes.
  This dates from milestone 4 and had been read as flakiness in the test.
- **Two flaky scheduler tests were fixed rather than tolerated.**
  `testForegroundJumpsAheadOfQueuedBackground` released all four holding transfers at once,
  so both queued transfers were admitted and which body ran first was the executor's
  business; it now frees exactly one slot. `testWindowIsSplitBetweenRunningTransfers`
  compared `values.first` and `values.last` of an array four concurrent bodies append to; it
  now compares the sorted multiset. The suite has been green on every run since.

### State the VM was left in

No locations, no File Provider domains, no `~/Library/CloudStorage` entries, no
`sshdrive-*` control sockets and no `ssh` masters, `~/m5` and `~/m5b` removed from the
server, the presence-override file deleted, and `sshdrive doctor` green apart from the
expected uninstall note. Four orphaned `ssh -N` masters from earlier sessions (ppid 1,
sockets already unlinked, so `-O exit` could not reach them - the trap the milestone 2
results record) were killed by hand. Screenshots from the spinner pass are in `~/m5-shots/`.
The signed Debug build is installed at `/Applications/SSH Drive.app` and the agent is
running.

---

## 2026-09-04 (milestone 4) - read-write: the section 5.5 upload protocol, conflict copies, symlinks (S8), Finder tags (S10)

Milestone 4 end to end: create, modify, delete, rename and move through the real
transport, the temp-file-plus-rename upload with its mode and mtime restore, conflict
copies, local xattrs and Finder tags, `.DS_Store`, and section 5.7's symlink handling.
Same headless VM (macOS 26.4.1 arm64, `OpenSSH_10.2p1`), the signed Debug build from
`scripts/mac-build.sh signed` installed over `/Applications/SSH Drive.app` with `ditto`.
Testbed up on the Mac; two servers were used, `deb` (2201, OpenSSH `sftp-server` on
Debian) and `alp` (2206, busybox and `internal-sftp` on Alpine). Steps are in
`milestone-4.md`.

**355 package tests, 0 failures** (was 295; 31 skipped without the testbed). The 60 new
ones are `SymlinkPolicyTests` (section 5.7's table, both root spellings, the create and
move checks), `RemoteWriterTests` (the upload protocol against `FakeTransport`: the temp
file, the create-versus-overwrite rule, the conflict copy and its naming, the in-flight
set, the stale-temp rule, the delete rules, the case-only rename against a
case-insensitive double, a server whose plain `rename` overwrites, and a directory the
account cannot write), `RowBuilderTests` (the xattr and tag hash in the metadata version,
the symlink check on the row, the generation bump, the read-only mapping) and
`LocalAttributesTests`.

### What was built

The write half of section 5.5 now lives in `AgentCore` as `RemoteWriter`, an actor that
owns the transport and the in-flight set and **never touches the index**: the agent reads
the row, hands the writer the three fields the conflict check needs, and writes the result
back itself, so `LocationRuntime` stays the only writer of the index and every rule in
section 5.5 is testable against the fake backend with no database at all. Beside it,
`RowBuilder` (every derived field of a row, including section 5.7's lexical check) and
`SymlinkPolicy` (that check, and nothing else). The transport grew one primitive,
`writeExclusive`, because the conflict check has to sit *between* the bytes landing and
the rename and the transport cannot own both halves.

### S8 - symlinks

| Question | Answer |
|---|---|
| Does the system create a real symlink under CloudStorage? | **Yes.** `lrwx------`, and `readlink` returns the row's target |
| Does a relative target resolve inside the mount? | **Yes.** `cat Docs/rel-inside` returns the contents of `note.txt` |
| Is an absolute in-root target rewritten? | **Yes.** `/home/alec/m4/Other` is served as `../Other` |
| Are escaping targets omitted? | **Yes**, with `hidden = 1` and a reason in "not shown" |
| Does Finder badge it? | **Yes**: Kind **"Alias"**, arrow badge, badged *folder* icon for a link to a directory |
| How does a dangling one present? | **Identically.** Same badge, same Kind, size = the target string's length, no broken-link marker |
| Does `ln -s` reach `createItem` with the target intact? | **Yes**, and escaping and absolute targets never leave the Mac |

Two things the runbook could not have guessed. **SFTP v3's `readdir` carries no link
target**, so the "once per link at enumeration time" check costs a `readlink` per link
before its row can be built. And **a refused `ln -s` is not a message the user sees**:
`ln -s` exits 0, the system keeps the item locally, and the refusal comes back as its
`uploadingError` (`NSFileProviderErrorCannotSynchronize`, -2005) with the system's own
wording. Section 5.7's sentence about the target having to be relative and inside the
share can only reach the user through `sshdrive status`'s sync-error list.

### S10 - Finder tags and the xattr hash

Tags arrive as **`tagData` and nothing else**: one `modifyItem` with
`changedFields = 0x10` (`NSFileProviderItemTagData`), an empty `extendedAttributes`
dictionary, and a 453-byte **`NSKeyedArchiver` archive** - not the
`com.apple.metadata:_kMDItemUserTags` property list the xattr holds, which is why the row
stores and serves it opaquely and never parses it. Nothing reaches the server. The
metadata version moves with it (`xattrHash cbf29ce484222325 -> e2a2e7907f0e585a`), the
tags survive an eviction and a re-download - the system rebuilds the xattr from the
`tagData` the item returns, which is the S4 loss this design exists to prevent - and the
system asks **once**.

**And it asks once with the version frozen too.** With `debug fault --frozen-metadata on`,
which replies with the metadata version the item already had, the same single `modifyItem`
arrived and no more over sixty seconds. So the xattr hash is **not** what stops a retry
loop; there is no retry loop on 26.4, for the same reason a `modifyItem` reply is believed
at all (S3). What the hash is for is the other direction: it is the only thing that moves
an item's version when the *agent* changes the stored blob, which a restore from the index
backup does, and without it the system would keep serving tags that are no longer there.
Section 5.4, section 5.3 and section 13 corrected.

One trap for the next person: `xattr` and Finder both **follow a symlink**, so a link's
row shows its target's tag colour and `xattr <link>` reads the target's attributes. It is
not evidence about the link.

### The write matrix, checked server-side

| Step | Result |
|---|---|
| create | temp file + non-overwriting rename, `0644`, nothing left behind |
| create an executable | `0755` survives the rename (`setstat` after it) |
| modify | `posix-rename@openssh.com` overwrite, mode kept |
| modification date | `touch -t 202401021530.45` -> the same instant on the server, whole seconds |
| rename in place | plain rename |
| rename across directories | one rename, paths rewritten |
| move of a directory subtree | one rename; every descendant row rewritten |
| delete a file | `remove` |
| `rmdir` a non-empty directory | refused, item left in place |
| `rm -r` | server-side depth-first walk, `lstat` before each descent |
| write to a read-only item | refused up front by the served flags; nothing sent |
| `chmod +x` and `-x` | `.fileSystemFlags` -> `setstat`, `0644 <-> 0755` |
| create onto a taken name | `lstat`-confirmed `.filenameCollision` |
| stale temp files | ours removed at once, another Mac's after 30 days |
| a lost master | `-1004` serverUnreachable, the edit in the pending set, `list` says offline |

The read-only row is worth quoting because it is derived, not guessed:
`ro/locked.txt mode=666 caps=65 fsFlags=2` - a `0666` file inside a `0555` directory gets
reading and evicting only, so the kernel refuses the write from the flags we served and
nothing is ever sent. Section 5.4's most-argued paragraph, end to end.

### Three assumptions that failed

**Section 5.5's eviction after a conflict copy cannot be a single call.** The conflict
path itself works exactly as written - the local content lands in
`c2 (conflicted copy from chosen-newt 2026-09-04 at 19.57.28).txt`, the destination keeps
the remote bytes, the remote item is returned - but the `evictItem` that has to follow the
reply was refused:

```
"errorDescription" : "The file ‘conflict.txt‘ cannot be evicted.", "errorCode" : -2008
```

`-2008` is `NSFileProviderErrorNonEvictable`: the system is still finishing the
modification it has just been told about. The same call a few seconds later succeeds, and
the next open then downloads the remote content. Without it the replica keeps the *local*
bytes under the *remote* version for ever, which is the entire reason the eviction is
there (S3, this morning). The conflict path now retries with a doubling backoff from
0.25 s, seven attempts, logging either way; the first retry has been enough every time.
And it signals the working set, without which the copy's anchor is a row nobody asks for
and Finder never shows it, because a folder is enumerated once, ever (section 6.5).

**A `.DS_Store` written into the mount never reaches the extension at all.** No
`createItem`, no `modifyItem`, no row; the system keeps the file in the replica and
reports it through `fileproviderctl evaluate` as an ordinary item with `isUploaded = 0`
and `isUploading = 0`, and never asks anyone to upload it. The server stays clean for
free. Section 5.4's local-only path (`hidden = 3`, `local_content`) is therefore not
exercised by the case it was written for; it is kept, because it is one branch, because
the exclusion is the system's choice rather than a contract, and because it is the path
any other writer of a `.DS_Store` would take. Section 5.4 corrected.

**"Deleted rows are deleted" needed one exception.** A local-only row has no remote
content by definition, so a `readdir` that does not mention it is not evidence that it
went. Without the exception the first listing after a local-only create deletes the row
and the user's file with it. Section 5.3 corrected.

### busybox and `internal-sftp` (`alp`, 2206)

The rename-over-existing and `setstat` paths on a server that is neither GNU nor OpenSSH's
external subsystem: `rename-check` reports `renameRefusesAnExistingName: true` and no
preflight needed, a create with `chmod +x` lands `-rwxr-xr-x`, a modify keeps `0644`, a
create onto a taken name is a confirmed collision, `chmod +x` on an existing file reaches
the server, `rmdir` of a non-empty directory is refused and `rm -r` takes it, and the
symlink policy hides `esc -> /etc/passwd` while showing `rel -> note.txt`. Alpine's
`internal-sftp` offers the same OpenSSH extensions as the external `sftp-server`
(`posix-rename`, `fsync`, `lsetstat`, `limits`), so nothing in section 5.5 degrades there;
the capability report reads `5/8 optimal`, the two `◐` being busybox `find`.

### Three smaller things worth writing down

- **`launchctl kill TERM` plus `open -g` does not reinstall the agent.** launchd brings it
  back before `ditto` has finished, `open -g` finds it running and does nothing, and every
  measurement is then taken against the old binary. That cost an hour: the tell was
  `debug index dump` missing a field the source had, and `strings` on the installed binary
  proving the field *was* there. `sshdrive agent restart` is the reliable form, and
  `ping`'s `interfaceVersion` is the cheap check.
- **`pgrep` counts zombies.** An `ssh` mux client killed with `-9` stays in `pgrep -f`
  output as `Z` until the agent reaps it, which makes "did I actually kill the master?"
  unanswerable from `pgrep` alone; `ps -o stat` is the one to read. Also: a location that
  has been restarted can be holding **two** masters, so a lost-connection test has to kill
  them all. Both belong to milestone 5.
- **`TransferSchedulerTests.testForegroundJumpsAheadOfQueuedBackground` is timing-flaky.**
  It failed once in five runs on a loaded VM and passed on every re-run, including three
  in a row with `--filter`. Nothing in milestone 4 touches the scheduler; the test races a
  `Task.sleep` against the admission order it is asserting, and it wants a barrier rather
  than a sleep before somebody spends an hour on it.
- **macOS asks for Local Network access in the app's name on first connect.** *"Allow
  “SSH Drive” to find devices on local networks?"* appeared while the mount was in use
  against a server on the host's vmnet segment. A NAS is exactly a device on the local
  network, so this is the ordinary case rather than an edge one, there is no entitlement
  that suppresses it, and a launchd agent has no window to put it over. Section 10 and
  section 13 record it; `add`, `doctor` and the cask's `caveats` are where it has to be
  said.

### State the VM was left in

No locations, no File Provider domains, no `~/Library/CloudStorage` entries, no
`sshdrive-*` control sockets, every fault off, `~/m4` and `~/m4a` removed from both
servers, and the testbed trees back to what `testbed/README.md` documents. The signed
Debug build is installed at `/Applications/SSH Drive.app` and the agent is running.
Screenshots from the S8 pass are in `~/m4-shots/` on the VM. `sshdrive doctor` is green
apart from the two expected warnings.

---

## 2026-09-04 (milestone 3, part 2) - the CLI: `add` with relayed prompts, `list`/`show`/`remove`/`set`, and the section 8.1 capability report

Section 8's user-facing half, section 4.2's collect connection driven from a terminal, and
section 8.1's report. Same headless VM (macOS 26.4.1 arm64, `OpenSSH_10.2p1`), the signed
Debug build from `scripts/mac-build.sh signed` installed over `/Applications/SSH Drive.app`
with `ditto`. Testbed up on the Mac; seven services were used (`deb` 2201, `deb-kbdint`
2204, `deb-maxsess` 2205, `alp` 2206, `bastion-a` 2210 and, behind it, `bastion-b` and
`inner`). Every `add` was driven over ssh with its answers on stdin, which is a pipe, so
the hidden-tty read falls back to a line read - that path is what a script and a CI run
take too.

**295 package tests, 0 failures** (was 246; 31 skipped without the testbed). The 49 new
ones are the destination and `set`-key parser (`ConfigTests`), the `ssh -G` attribution
diff and its display (`SSHProcessTests`), the add-flow state machine and the broker driven
through `AskpassHarness` (`AgentCoreTests`), and three for the nested-transaction fix
below (`IndexTests`).

### What `add` does, in order

The whole of section 8's paragraph, on one screen:

```
$ sshdrive add deb alec@192.168.64.1:2201 --identity ~/.ssh/sshdrive-spike
192.168.64.1 resolves to:
  user alec (from this location)
  hostname 192.168.64.1 (ssh default)
  port 2201 (from this location)
  identityfile /Users/alec/.ssh/sshdrive-spike (from this location)
  identitiesonly yes (from this location)
  …
Your terminal's PATH differs from the login shell snapshot SSH Drive will use.
  terminal:  /Applications/SSH Drive.app/Contents/MacOS:/usr/bin:/bin:/usr/sbin:/sbin
  SSH Drive: /opt/homebrew/opt/openjdk@17/bin:…:/Library/Apple/usr/bin
Your terminal's SSH_AUTH_SOCK differs from the one SSH Drive will use.
  terminal:  (unset)
  SSH Drive: /var/run/com.apple.launchd.be1Nf5Ktqm/Listeners
Connecting once to check, with the command SSH Drive will use later.
Connecting for real, from the stored answers.

Added deb (1EF434B3-164B-4F1B-B5B8-6C96451C9B5A)
  server     alec@192.168.64.1:2201
  root       /home/alec  (7 entries)
  mount      ~/Library/CloudStorage/SSHDrive-deb
  Capabilities  6/8 optimal   probed 0s ago
```

The attribution is the section 4.1 diff, and it earns its keep: every line above says
which of the three precedence levels it came from, and an `--identity` shows up as *from
this location* rather than being confused with a config file's `IdentityFile`. Against the
`spike-*` aliases the same display credits the config instead.

**"Connecting once to check" and "Connecting for real" are two different connections and
that is the point.** The collect connection is an `SSHMaster` on a scratch control path -
the same `ssh` command line the location's own master runs, differing only in
`StrictHostKeyChecking` (`ask` rather than `yes`, so section 4.3's question can be raised)
and in the socket it binds. It needs no remote command, because the control socket
appearing *is* authentication having succeeded, which is also why it would work against a
`ForceCommand internal-sftp` account. It is then shut down and the location connects
again, unattended, from the stored answers. Section 4.2's "a location that passes `add`
works from the agent" is therefore demonstrated on every `add` rather than asserted.

### The seven scenarios

| Scenario | Server | Result |
|---|---|---|
| key auth, no prompts | `alec@192.168.64.1:2201` | added; 7 entries; `6/8 optimal` |
| password relayed and stored | `pw@192.168.64.1:2201` | one prompt, answered on the terminal, `password:pw@192.168.64.1:2201` written **after** the connection authenticated |
| second location, same host | `pw@192.168.64.1:2201 --path /home/pw/.cache` | **no prompt at all**; the shared item answered it |
| one-hop chain | `alec@inner --jump hop@192.168.64.1:2210` | two prompts, keyed `password:hop@192.168.64.1:2210` and `password:alec@inner:22` |
| two-hop chain | `alec@inner --jump hop@192.168.64.1:2210,hop@bastion-b` | three prompts, three items, **a different password on each hop** |
| keyboard-interactive | `kbd@192.168.64.1:2204` | one prompt, stored as `password:kbd@192.168.64.1:2204` |
| fresh `known_hosts`, answered **no** | `alec@192.168.64.1:2206` | exit 1, "The server's host key was not accepted, so nothing was added", `known_hosts` untouched, no location |
| the same question, answered **yes** | `alec@192.168.64.1:2206` | added; `known_hosts` gained one entry; `5/8 optimal` (busybox) |
| wrong password | `keypass@192.168.64.1:2201` | exit 1, `ssh said: Permission denied (publickey,password)`, **nothing stored and no location** |
| a remote path that does not exist | `pw@…:2201 --path /home/pw/nope` | exit 1, "The server has no /home/pw/nope …", no location left behind |

The two-hop transcript, trimmed, is the one worth keeping:

```
  jump chain hop@192.168.64.1:2210 -> hop@bastion-b (rebuilt as SSH Drive's own
      ProxyCommand; never handed to ssh)
It will be stored in your keychain as password stored for hop@192.168.64.1.
hop@192.168.64.1's password:
It will be stored in your keychain as password stored for hop@bastion-b.
hop@bastion-b's password:
It will be stored in your keychain as password stored for alec@inner.
alec@inner's password:
Connecting for real, from the stored answers.
Added inner …
  jump       192.168.64.1 -> bastion-b
  auth       password stored for alec@inner
  auth       password stored for hop@192.168.64.1
  auth       password stored for hop@bastion-b
```

Section 4.2's reason for keying on `user@hostname:port` rather than on the location is
visible in three lines: the two bastions have deliberately different passwords and each
hop's prompt named its own host. The hops are told apart from the master by the argv the
askpass sends, exactly as milestone 2 established; nothing here parses the prompt text.

**Rollback is real.** Every failure above left `config.json`, the domain list and the
keychain as they were. Three of them fail before anything is written at all (the location
is created only after the collect connection succeeds), and the fourth - a bad
`--remote-path`, which is only discovered by the *second* connection - removes the domain,
the runtime, the config entry and the domain directory before it reports.

### `list`, `show`, `status`, `set`, `remove`

- **`list`** is the section 8 table: name, destination, mounted, state, TTL, and the
  secrets by kind. It connects nothing: state comes from runtimes that are already up, so
  a `list` on a laptop with no network is instant. `status --probe` is the way to ask for
  a connection on purpose.
- **`show`** prints the `ssh` binary and version, the whole `ssh -G` resolution with its
  attribution, the keywords section 6.1 overrode, the environment snapshot, whether the
  location runs `IdentityAgent=none` or through the key agent, the rebuilt `ProxyCommand`,
  the mount path, the last error, the stored secrets **by kind and never their values**,
  and the capability report.
- **`status`** carries section 8.1's report with the glyphs and the `upgrade:`/`note:`
  lines. Against `deb-maxsess` it also carries the part-1 channel budget:

```
maxsess   alec@192.168.64.1:2205   mounted   online   TTL 1h
       channels 2 at a time, no bulk channel, shell
         note: the server allows two channels at a time (MaxSessions 2): the bulk transfer
         channel is dropped and transfers share the metadata channel, …
       server sees us as uid=2401(alec) gid=2401 groups=2401
```

  and against `alp` the busybox `find` shows up twice, which is the report doing real work
  rather than printing a constant:

```
alp   5/8 optimal
  ◐ change detection  sweep (find -mmin over the root set; a rename or chmod moves ctime,
                      not mtime, so those are missed until the next full sweep)
  ◐ change evidence   size + mtime (same-second rewrites of equal size are missed)
        upgrade: a `find` that takes -printf (GNU findutils), or the helper
```

  `--json` emits the same objects (`{feature, level, best, glyph, upgrade, note}`), so the
  text and the machine-readable form cannot disagree - the agent computes both and the CLI
  only lays out.
- **`set`** applied `nickname` (domain re-created, `SSHDrive-alp` became
  `SSHDrive-alpine`, with the warning section 8 asks for - S9 is still unanswered, so the
  documented behaviour is what runs), `cache-ttl 1d`, and `option add|remove`. A bad value
  is refused and changes nothing (`"2h" is not a valid cache-ttl; expected
  15m|1h|12h|1d|1w|1mo|never`). `host|user|port|identity` re-run the collect connection
  before saving, as section 8 requires.
- **`remove`** asks section 8's confirmation (`n` leaves everything and exits 1), takes the
  domain, the index directory and the location, and applies the shared-item rule exactly:
  removing `debpw` while `debpw2` still named `password:pw@192.168.64.1:2201` left the item
  alone, and removing `debpw2` deleted it. `remove --all` cleared four locations and the two
  chain passwords in one go.
- **`doctor`** grew the four transport checks: `ssh -V`, `~/.ssh/config` parse warnings from
  a `ssh -G` of a name nothing can match, orphan control sockets (reported, never swept -
  `doctor` is a diagnosis), and keychain reachability under the access group. The
  login-shell snapshot summary was already there.

### Two assumptions that failed

**Section 5.3's "a listing is one transaction" could not be applied as written.** The first
real `add` died with `SQLite error 1: cannot start a transaction within a transaction`. The
listing's own body calls two things that are each a transaction in their own right -
`appendAnchor` for every changed row, and `delete`, which section 5.3 requires to write the
row and its deletion anchor together - and SQLite has no nested `BEGIN`. Both rules are
right; the helper was wrong. `SQLiteConnection.transaction` now nests, with `SAVEPOINT` for
every level below the outermost, so an inner failure its caller catches undoes only its own
writes and one that propagates still rolls the whole listing back. Three tests cover it.
Section 5.3 and section 13 say so now. (Part 1 measured the one-transaction listing before
the anchor calls moved inside it, which is why this was not seen then.)

**Section 4.2's 60 s authentication deadline cannot cover the collect connection.** It is
written as "every connection", and it exists because nothing may sit waiting for a human on
an unattended reconnect. But the collect connection is the one where somebody *is* at the
keyboard: reading a fingerprint off the screen and typing a password for each of three hops
took well over a minute in the two-hop run, and a 60 s kill lands in the middle of it. The
collect connection now runs to 300 s (the broker's token expiry moves with it), and the
master `add` brings up immediately afterwards carries the ordinary 60 s - which is the
connection that has to work unattended and therefore the one worth bounding. Section 4.2
and section 13 corrected.

### Three smaller things worth writing down

- **The CLI has to export an XPC object.** Section 4.2 has the agent "call back to the CLI
  over the same XPC connection", which the listener did not allow for: it set the
  extension's interface as `remoteObjectInterface` for every non-askpass peer. It now picks
  by executable, the same rule that gives `sshdrive-askpass` its one-method interface, so a
  `sshdrive` peer gets `SSHDriveCLIProtocol` (one prompt method, one note method) and
  everyone else the extension's.
- **The CLI's stdout must be unbuffered.** stdout is *fully* buffered when it is a pipe -
  which every transcript, `script -q` run and CI invocation is. The agent writes a relayed
  prompt through the file descriptor so it reaches the terminal before the read blocks on
  it; a buffered `print` from the CLI's own report then lands behind it, and the transcript
  stops matching what happened. `setvbuf(stdout, nil, _IONBF, 0)` once, in the client.
  Related: on a pipe nothing supplies the newline the user's Return would, so the CLI writes
  one itself after a piped read.
- **Reinstalling the app with `rm -rf` first loses the domains.** `NSFileProviderManager.domains()`
  then answers "The application cannot be used right now" until the extension is
  re-registered and the app relaunched. `ditto` **over** the existing bundle keeps
  everything, and `open -g "/Applications/SSH Drive.app"` by path rather than
  `open -g -a "SSH Drive"` by name is what stops LaunchServices registering the copy in
  the build directory instead - `sshdrive doctor`'s "app in /Applications" line is what
  catches that, and it caught it here. Worth knowing before blaming the code; nothing in
  the design depends on either.

### State the VM was left in

No locations, no File Provider domains, no `~/Library/CloudStorage` entries, no
`sshdrive-*` control sockets, and **an empty keychain** - the five items milestone 2 left
were deleted at the start of this pass so the prompt relay was genuinely exercised, and
everything this pass stored was removed with its location. `known_hosts` differs from the
backup by exactly the `[192.168.64.1]:2206` entry the host-key test removed and re-added.
Three `ssh -N -M … cm-hop@192.168.64.1-2210` and one `cm-hb4` process from the milestone-2
pass (15:17-15:41) are still running; they use the testbed config's own `ControlPath`, not
ours, which is itself the evidence for section 6.1's claim that our rebuilt hop touches
neither.

---

## 2026-09-04 (milestone 3, part 1) - the transfer scheduler, permissions to capabilities, and S3's deferred containment test

The §6.2 transfer scheduler on a second bulk channel, §5.4's permissions and hidden names,
and the containment half of S3 that milestone 1 deferred to a real server. Same headless VM
(macOS 26.4.1 arm64, `OpenSSH_10.2p1`), the signed Debug build from
`scripts/mac-build.sh signed` (`MAC_DIR=~/sshdrive`) installed over `/Applications/SSH Drive.app`
with `ditto` and restarted with `open -g`. Testbed up on the Mac; `deb` (2201) and
`deb-maxsess` (2205) were the two servers used.

**246 package tests, 0 failures** (was 214; 31 skipped without the testbed). The 32 new ones
are a new `AgentCore` module - `ItemDerivation`, `NameVisibility` and `TransferScheduler`
moved out of `Apps/Agent` so they can be unit-tested without an app bundle.

### The scheduler, on a real mount

Two SFTP mux clients on one master, visible in `ps`:

```
/usr/bin/ssh -N -o ControlMaster=yes -o ControlPath=$TMPDIR/sshdrive-159bb6b1 … 192.168.64.1
/usr/bin/ssh -F /dev/null -S $TMPDIR/sshdrive-159bb6b1 … -s 192.168.64.1 sftp   <- metadata
/usr/bin/ssh -F /dev/null -S $TMPDIR/sshdrive-159bb6b1 … -s 192.168.64.1 sftp   <- bulk
```

Eight 32 MiB files opened at once from a shell loop through
`~/Library/CloudStorage/SSHDrive-deb`, and the agent's own log:

```
159BB6B1…: transfer queued (4 running, 1 waiting)
159BB6B1…: transfer queued (4 running, 2 waiting)
159BB6B1…: 6 transfers held, above the six-fetch ceiling
159BB6B1…: transfer queued (4 running, 3 waiting)
159BB6B1…: 7 transfers held, above the six-fetch ceiling
159BB6B1…: transfer queued (4 running, 4 waiting)
```

`peakRunning 4`, `peakHeld 8`, every one of the eight delivering its full 33,554,432 bytes,
and the window share visibly splitting (16, 8, 5, 4 as the four filled up).

- **A 64 MiB upload** through the same scheduler and the same temp-file-plus-rename path:
  0.73 s, 87 MiB/s, on the bulk channel, streamed a megabyte at a time so it never sits in
  the agent's memory.
- **A cancel mid-fetch**: a 512 MiB file cancelled 300 ms in stopped at 52,485,120 bytes and
  answered "The transfer was cancelled."; cancelled 30 ms in, at 45,173,760. Uncancelled the
  same file takes 2.9 s. A queued transfer that is cancelled never starts.
- **A partial fetch**, 1 MiB at offset 16 MiB, returned exactly 1,048,576 bytes.

### The §6.2 assumption that failed

**The six-fetch ceiling bounds an eager subtree and nothing else.** S6 measured 38 transfers
running in strict batches of six and §6.2 concluded "the four running plus at most two
waiting is everything the agent ever holds". Eight `cat`s from a shell reached the extension
as **eight simultaneous foreground `fetchContents` calls**, so the agent held eight. The
scheduler now treats six as a size, not a cap: a seventh arrival is admitted and counted
(`overCeilingAdmissions`, which `status` shows) rather than refused, because refusing a
`fetchContents` the system did make fails a user's open for the sake of a measurement.
§6.2 and §13 corrected.

### `MaxSessions`: what the design wants at 2, and how the probe asks

`deb-maxsess` has `MaxSessions 2`. The `-N` master carries no session of its own, so two is
two *channels*, and master + metadata + bulk is exactly at the limit - with nothing left for
an exec channel. §6.1 already decides it: at 2 the bulk channel is dropped, transfers share
the metadata channel under the scheduler, and the second channel is kept for the shell,
because tier 1's sweep, the capability probe and the `id` identity all need exec and nothing
can share an exec channel, while transfers can share an SFTP one. So the probe's real
question is **"may I hold three at once"**, and two opens answer it: the second *is* the bulk
channel, and the third stands in for the exec channel and is closed again. Against 2205:

```
"channels": { "concurrentChannels": 2, "bulkChannel": false, "execChannel": true,
  "note": "the server allows two channels at a time (MaxSessions 2): the bulk transfer
   channel is dropped and transfers share the metadata channel, so a large download slows
   listings; the second channel is kept for shell access (sweep, probe, helper)" }
```

One `sftp` mux client in `ps`, the `id` probe still answering (`uid=2401(alec)`), the
scheduler's window share halved to 8 so the shared channel keeps request slots free for the
metadata calls served ahead of transfers, and uploads and fetches both working on it.

Two things worth writing down. **A channel is proved open by completing the SFTP handshake on
it**: `ssh` spawns successfully whether or not the session was granted, and only the refusal
on stderr, or a handshake that never lands, tells the two apart. And **the agent never sees a
server banner**, so §6.1's "cached once per server banner, re-probed when the banner changes"
cannot be implemented as written: its `ssh` runs at `LogLevel=ERROR`, which prints no remote
version, and a mux client speaks to the master's socket rather than to the server. The cache
in `domains/<id>/capabilities.json` is keyed by the location and invalidated only by an
explicit re-probe; a cached budget that has stopped holding is noticed anyway, because
opening the bulk channel is what the cached answer is used for. §6.1 and §13 say so now.

### Permissions to capabilities (§5.4), against a real `id`

The identity comes from one `id -u; id -g; id -G; id -un` exec channel through `RemoteScript`
at connect: `uid=2001(alec) gid=2001 groups=2001` on `deb`, `uid=2401(alec)` on
`deb-maxsess`. Where there is no shell - a `ForceCommand` account, or a `MaxSessions 1`
server with no channel to spare - the identity stays unknown and §5.4's SFTP-only rule
applies. The derived rows, read back out of the index:

| Path | mode | `capabilities` | `fs_flags` |
|---|---|---|---|
| `data/perm` (dir) | 0755 | 111 | 7 (exec, read, write) |
| `data/perm/script.sh` | 0755 | 111 | 7 |
| `data/perm/plain.txt` | 0644 | 111 | 6 (read, write; **no** exec) |
| `data/perm/rootowned.txt` | 0444 | 109 (no writing) | 2 (read only) |
| `data/perm/ro` (dir) | 0555 | 109 (no adding sub-items) | 3 (search, read) |
| `data/perm/ro/locked.txt` | **0666** | **65** (reading + evicting only) | 2 |

The last row is the paragraph §5.4 spends the most words on: a writable file in a read-only
directory is shown **locked**, because replacing content goes through a temp file in that
directory, and renaming and deleting follow the parent's write bit. It is derived, not
guessed - and it is the row, not the extension, that says so.

### Hidden names (§5.4)

`data/weird` seeded with `Makefile`/`makefile`, an NFC and an NFD `é.txt`, and a `.DS_Store`,
on top of the testbed's own ten weird names. Through the mount, ten entries; and:

```
"notShown": [
  { "path": "data/weird/latin1-caf\xff", "reason": "the name is not valid UTF-8, which macOS cannot represent" },
  { "path": "data/weird/makefile",  "reason": "the local filesystem cannot tell it from \"Makefile\"; rename one on the server" },
  { "path": "data/weird/é.txt",     "reason": "the local filesystem cannot tell it from \"é.txt\"; rename one on the server" }
]
```

`Makefile` wins on the byte-wise rule (`M` is 0x4D, `m` is 0x6D) and an incumbent keeps its
slot regardless of `readdir` order. The server-side `.DS_Store` is not listed at all and is
not in "not shown" either: §5.4 says it is never enumerated, so it gets no row, which is what
tells it apart from a hidden name. Sockets and FIFOs, `.`/`..`, and our own
`.sshdrive-upload-*` temp files are dropped the same way. A create or rename onto a hidden
name fails `.filenameCollision`.

### S3's deferred containment test, on a real server

Everything below was done over ssh as `alec@deb`, inside that account's own home.
`data/swap/` was created with an `inside.txt`, listed and read through the mount, then
replaced: `mv data/swap data/swap.real && ln -s /etc data/swap`.

**The §9.1 assumption that failed.** §9.1's "never descend through a link" was written as a
rule for recursive delete. It has to hold for enumeration too, because **SFTP `opendir`
follows a symlink**: with the swap in place, forcing the agent to list `data/swap` returned
`/etc` and put `passwd`, `shadow`, `skel`, `ld.so.cache` and eighty other names into the
index as rows under the mount root. Nothing outside the account's own tree was ever written
or deleted, and Finder never showed them - the replica had already cached the pre-swap
listing, and §6.5's "a folder is enumerated once, ever" meant nothing re-asked - but the
index is exactly where they must not be, and a pin or a sweep would have acted on them.

Fixed: every listing re-`lstat`s its own directory before `readdir` and refuses to descend
when the answer is no longer `directory`; the row is rewritten from that `lstat`, every row
beneath it is deleted, and the container answers `.noSuchItem`. §9.1 and §13 corrected.
With the check in place, and the swap still in place on the server:

| Question | Answer |
|---|---|
| Rows anywhere under `data/swap` | **0** |
| `ls -la <mount>/data` | `swap` appears as `lrwx------ … swap -> ` (a link, empty target: §5.7's target rewrite is milestone 4) |
| `ls <mount>/data/swap` | the link itself, no contents |
| `cat <mount>/data/swap/passwd` | `No such file or directory` |
| `rm <mount>/data/swap/hostname` | nothing to remove; `/etc/hostname` untouched |
| `/etc` on the server afterwards | intact, 82 entries |

Restored afterwards: `rm data/swap && mv data/swap.real data/swap`, and `inside.txt` reads
back.

**`RelativePath` escape attempts**, handed straight to `createItem` with no shell and no
string path in between (`sshdrive debug transport escape`):

| `createItem` filename | Result |
|---|---|
| `..` | refused: `A path component may not be ".."` |
| `../escaped.txt` | refused: `A path component may not contain "/"` |
| `/etc/escaped.txt` | refused: `A path component may not contain "/"` |
| `.` | refused: `A path component may not be "."` |
| upload to `../escaped.bin` | refused: `A path component may not be ".."` |

**An absolute symlink target in `createItem`** is the one case that is not refused yet:
`createItem(filename: "escape-link", symlinkTarget: "/etc")` creates the link on the server,
at a path the chokepoint validated. That is §5.7's lexical inside-the-root check, which is
milestone 4 and is still a `TODO` in `LocationRuntime.createItem`. §9.1 holds regardless: the
target string is never joined to a remote path, and through the mount `ls escape-link` and
`cat escape-link-passwd` both answer `No such file or directory`, with zero index rows under
either. Both links were removed afterwards.

### Two more things a large directory taught us

- **A directory listing must be one transaction.** `ls` of the testbed's 10,000-entry
  `data/many` through the mount answered `ls: fts_read: Operation timed out` - with paging on
  *and* with paging off, so it was never the paging. Row by row, the listing is 10,000
  autocommits, each its own WAL frame; wrapped in one `BEGIN IMMEDIATE` the same `ls` returns
  all 10,000 names in 70 s cold and instantly warm. §5.3 and §13 say so now.
- **Paging works and the system follows it.** 2,000 items a page; the extension logs
  `enumerateItems container=41AC454A… page=E113FC6D…` for the continuations and the agent
  logs `paging 10000 entries of data/many in 2000s`. A page token is an offset into a listing
  the agent already holds, so a second page never re-lists the directory.

### State the VM was left in

The signed build is installed at `/Applications/SSH Drive.app` and the agent is running, for
whoever picks milestone 3 up. **No File Provider domains and no locations in `config.json`**;
`sshdrive doctor` reports "file provider domains: none" and no `sshdrive-*` control sockets
are left. The testbed trees are back to what `testbed/README.md` documents: `data/{many,tree,weird}`
on `deb` with the original ten weird names, nothing extra in `~alec`, and `deb-maxsess`
clean. The keychain items the milestone 2 pass left in place are still there.

---

## 2026-09-04 (assembled stack) - S2: the transport end to end, three real mounts, and what is left for a real Mac

The three milestone 2 modules (`SFTP`, `SSHProcess`, `Secrets`) merged into one stack, wired
behind the agent's `SFTPTransport`, and driven from Finder's own mount path. Same headless VM
(macOS 26.4.1 arm64, `OpenSSH_10.2p1, LibreSSL 3.3.6`), the signed Debug build from
`scripts/mac-build.sh signed` (`MAC_DIR=~/sshdrive`), installed over `/Applications/SSH Drive.app`
with `ditto` and restarted with `open -g`. Testbed up on the Mac. The three per-agent build
directories on the VM (`~/sshdrive-sftp`, `~/sshdrive-ssh`, `~/sshdrive-secrets`) are gone.

**214 package tests, 0 failures**, both without the testbed (31 skipped) and with
`SSHDRIVE_TESTBED=1` (2 skipped; the two that need a real Mac).

### What the seams became

- **One `ByteStream`.** `SFTP` now depends on `SSHProcess` and uses its `ByteStream`;
  `SFTPByteStream`/`SFTPPipeByteStream` are gone. `PipeByteStream` kept its deadline-carrying
  `read(upTo:deadline:)` (the `bashbg` rule) and gained the bounded buffer the SFTP one had, so a
  1 GB transfer cannot outrun the parser into memory; the deadline-free spelling the wire client
  wants is a protocol extension, because deadlines there are per *request* (§6.2).
- **`SFTPClient` runs on a mux client in production.** `SSHMaster.openSFTPChannel()` ->
  `SFTPChannel.stream` -> `RealSFTPTransport.connect(stream:root:)`. `SFTPSubprocess` stays as the
  test path `SFTPIntegrationTests` uses. New `TestbedChannelTransportTests` covers the production
  route: list, write, read back, `lstat`, rename, delete over the master's socket, and a second
  channel opening on the same master after the first was killed.
- **One askpass environment,** in `XPCProtocols` (`AskpassEnvironment`), used by `Secrets`,
  `SSHProcess`, the agent and `sshdrive-askpass`. `SSHProcess` and `Secrets` meet on
  `AskpassTokenProviding`: `SSHMaster` mints a token per spawn, puts it in that child's
  environment, attaches its pid and retires it when the master goes. Mux clients get
  `removingAskpass(from:)`.
- **`askpassAnswer` is off `SSHDriveAgentProtocol`.** The askpass path is
  `SSHDriveAskpassProtocol` and nothing else.
- **`ProxyCommand` before `ProxyJump=none`, everywhere.** `debug secrets connect` no longer
  hand-rolls a hop: it calls `ProxyChainBuilder`, so it takes a whole comma-separated chain. And a
  `ProxyJump` written into a location's own `sshOptions` now reaches `ssh -G` (where the chain
  builder wants it) and is stripped from the master's command line, so "`ProxyJump` is never handed
  to `ssh`" is literally true.

### The debug hook the mounts were driven with

`sshdrive debug ssh add <name> <[user@]host[:port]> [--remote-path P] [--identity F] [--jump CHAIN]`
and `sshdrive debug ssh remove <name>`. Not `sshdrive add`: no `ssh -G` display, no two-pass
collect connection, no relayed prompts - those are milestone 3. It writes the location, connects
with whatever the keychain already holds, and is all-or-nothing (a location that cannot connect is
not left in `config.json`). `--identity` stores `IdentitiesOnly=yes` with it, as §4 says.

### Three mounts, each exercised through `~/Library/CloudStorage/SSHDrive-<name>`

| Mount | How | Result |
|---|---|---|
| `deb` | `debug ssh add deb alec@192.168.64.1:2201 --identity ~/.ssh/sshdrive-spike` | root canonicalised to `/home/alec`; `ls -la`, `ls -R data/weird`, `cat`, create, `mkdir`, `mv` into the new directory, `rm -r`. Every one reached the server. |
| `inner` | `debug ssh add inner spike-inner` (the alias's `ProxyJump spike-bastion-a,spike-bastion-b`), passwords put in place with `debug secrets store` | both hops answered from the keychain with **different** passwords, destination by key; `ls -R data`, write, `cat`, rename, delete, all confirmed on `inner` two hops away. |
| `enc` | `debug ssh add enc alec@192.168.64.1:2201 --identity ~/.ssh/sshdrive-spike-enc` | passphrase from `passphrase:/Users/alec/.ssh/sshdrive-spike-enc`, no tty anywhere; write, `cat`, rename, delete. |

All three came back after `sshdrive agent restart` without being re-added: `config.json` says
`mounted`, and `DomainManager.start()` spawns a master per location.

Two things worth knowing before repeating this:

- **A name the server no longer has stays in the mount.** Change detection is milestone 6, so a
  directory removed on the server by hand keeps its index row and keeps showing up. Nothing is
  wrong; there is simply nothing yet that notices.
- **`weird/` is served as it is.** `$(echo pwned)`, `quote'name`, `back\slash`, `*star*`,
  `[bracket]`, `space in name`, a name containing a newline and `utf8-café` all list and open
  through `ls -R` in the mount. The non-UTF-8 name is skipped, which is milestone 3's `hidden = 2`
  row rather than a real answer.

### The two-hop chain, as the master actually ran it

`ps` while `inner` was mounted, elided:

```
/usr/bin/ssh -N -o ControlMaster=yes -o ControlPath=$TMPDIR/sshdrive-90ea6950 -o ControlPersist=no
  … -o IdentityAgent=none
  -o ProxyCommand='/usr/bin/ssh' '-W' '%h:%p' '-o' 'ControlMaster=no' '-o' 'ControlPath=none' …
     '-o' 'ProxyCommand='\''/usr/bin/ssh'\'' '\''-W'\'' '\''%%h:%%p'\'' … '\''spike-bastion-a'\'''
     '-o' 'ProxyJump=none' 'spike-bastion-b'
  -o ProxyJump=none spike-inner
```

The three things §6.1 insists on are all visible: `ProxyCommand` written **before**
`ProxyJump=none` at both levels, `%h:%p` doubled to `%%h:%%p` for the hop one level down, and
`ControlPath=none` on every hop. A user's own multiplexing master for the same bastion
(`ssh -N -M -o ControlPath=~/.ssh/cm-hop@192.168.64.1-2210`, which the testbed's `~/.ssh/config`
sets up precisely so this can be falsified) was running throughout, and our hop did not attach to
it.

### S2 items this pass answered

- **The login shell snapshot, from the launchd-started agent: PASS.** `sshdrive doctor` now prints
  it. It reports `/bin/zsh` and the Homebrew `PATH` (`/opt/homebrew/bin` and the rest), which
  launchd's own `/usr/bin:/bin:/usr/sbin:/sbin` does not have - that is the `ProxyCommand` that
  calls a Homebrew tool, working.
- **A key reachable only through an `SSH_AUTH_SOCK` exported in `.zshrc`: PASS.** With
  `export SSH_AUTH_SOCK=/tmp/sshdrive-s2-agent` appended to a throwaway `~/.zshrc` and the agent
  restarted, `doctor` reported that socket in place of launchd's Apple `ssh-agent` listener
  (`/var/run/com.apple.launchd.*/Listeners`), and the agent pass below authenticated through it.
  `.zshrc` was restored afterwards.
- **The two-step collect connection, first pass, against a key `ssh-agent` already holds: PASS.**
  `~/.ssh/sshdrive-spike-enc` loaded into the agent; `debug secrets connect --purpose collect
  --identity ~/.ssh/sshdrive-spike-enc` (which runs `IdentityAgent=none`) raised the **passphrase**
  prompt rather than signing through the agent: `prompts 1`, `answeredFromKeychain 1`,
  `exitStatus 0`. Delete the keychain item and the same prompt is recorded as a miss keyed
  `passphrase:/Users/alec/.ssh/sshdrive-spike-enc` - which is exactly what `add` relays to the
  terminal and then stores - after which `ssh` falls through to `alec@192.168.64.1's password: `,
  recorded as a second miss keyed by the destination. That second miss is §4.2's "your key files
  did not authenticate and the server accepts passwords" branch, visible in the data.
- **The second pass, for an agent-only key: PASS.** A fresh ed25519 key added to `ssh-agent`, its
  public half appended to `deb`'s `authorized_keys`, and the **private file deleted**. First pass
  (`IdentityAgent=none`): `exitStatus 255`, one password prompt,
  `Permission denied (publickey,password)`. Second pass (`--with-key-agent`): `exitStatus 0` with
  **zero prompts**. That is the `agentDependent` recording, end to end.
- **`agent refused operation` could not be provoked here, and the reason matters.** OpenSSH's own
  `ssh-agent` locked with `ssh-add -x` does not refuse a signature: it reports *no identities*, and
  `ssh` exits with a plain `Permission denied (publickey,password)`. A socket whose agent has been
  killed, and a socket path that no longer exists, both produce the same line at `LogLevel=ERROR`.
  So §6.1's conclusion is stronger than it was written: stderr distinguishes **none** of the three
  key-agent states, not only the missing-socket one, and the pre-spawn `IdentityAgentCheck` probe
  is the only signal for a locked agent as well as an absent one. The `agent refused operation`
  string stays in the classifier because 1Password and Secretive are documented to produce it;
  neither is installable on this VM. §6.1 and §13 say so now.

### Throughput, as far as a container on the same Mac can say

The integration tests print rather than assert, and a `SSHDRIVE_TESTBED=1` run against
`spike-deb` (OpenSSH 9.2) says:

```
[spike-deb] limits: maxPacketLength 262144, maxReadLength 261120,
                    maxWriteLength 261120, maxOpenHandles 20475
[deb] pipelined write 64 MiB in 0.49 s = 129.6 MiB/s
[deb] pipelined read  64 MiB in 0.25 s = 252.1 MiB/s
[S2]  64 MiB: sshdrive 0.25 s (252.1 MiB/s); sftp(1) 0.68 s (94.6 MiB/s)
[deb] readdir data/many: 10000 entries in 0.10 s
```

Sixteen requests in flight at the server's own 255 KiB read size beats `sftp(1)` by about
2.7x here, which is what §6.2 meant by "`sftp(1)`-class throughput", and the 255 KiB inside
a 256 KiB packet that §6.2 quotes is confirmed on the wire. The 1 GB file
(`BIG_FILE: "1"` on the `deb` service) and the `rsync` comparison are still not run, and
none of this is a NAS over a network: a container on the same Mac is a floor.

### Still needs a real Mac

Unchanged from the S2 row of §11, and none of it is reachable from a headless VM: Tailscale SSH's
`none` auth (the testbed's `nopw` account is the same wire outcome, not the same implementation),
1Password or Secretive behind `IdentityAgent`, Apple's `UseKeychain`, a FIDO key's user-presence
notice and the 60 s authentication deadline firing against a touch, and the screen-unlock and
present-user re-arm after a deadline stop (§4.2, §5.6). The FIDO and PIN rows of §4.2's
classification table remain format strings plus unit tests.

### One trap this pass found

`ssh -O exit` over the control socket is how the agent sweeps orphans at start, and it works
(`Exit request sent.`, the master dies). But an orphan whose socket has **already** been unlinked
cannot be reached at all, and that is what a test leaves behind when it shuts its master down in a
detached `Task` inside a `defer`: the task can outlive the test process. Both testbed test files now
shut the master down in `tearDown`.

### State the VM was left in

No File Provider domains, no locations in `config.json`, `~/.zshrc` restored, the throwaway
`ssh-agent` and its key gone from the VM and from `deb`'s `authorized_keys`. Keychain items left in
place on purpose, for whoever picks this up: `password:pw@192.168.64.1:2201`,
`passphrase:/Users/alec/.ssh/sshdrive-spike-enc`, `password:hop@192.168.64.1:2210`,
`password:hop@bastion-b:22`, `password:alec@inner:22`. Delete them with
`sshdrive debug secrets delete --key <account>`.

---

## 2026-09-04 (night) - S2 askpass: the token protocol, the keychain, and the prompts `ssh` really sends

Same headless VM (macOS 26.4.1 arm64, `OpenSSH_10.2p1, LibreSSL 3.3.6`), the signed Debug
build from `MAC_DIR=~/sshdrive-secrets scripts/mac-build.sh signed`, installed over
`/Applications/SSH Drive.app` with `ditto` (never `rm -rf` plus a copy - that is the S1 f2
trap) and restarted with `open -g`. Testbed up on the Mac. Milestone 2 code: the real
`Secrets` keychain store, the askpass broker, `sshdrive-askpass`, and the agent's
askpass-only XPC interface.

### The prompt strings, captured rather than assumed

An `SSH_ASKPASS` script that logged `argv[1]` and `SSH_ASKPASS_PROMPT` and answered
nothing, run against the testbed from the VM. Verbatim, **trailing spaces included**:

| What | `argv[1]` | `SSH_ASKPASS_PROMPT` |
|---|---|---|
| password (`pw@…:2201`) | `pw@192.168.64.1's password: ` | **unset** |
| passphrase (`-i ~/.ssh/sshdrive-spike-enc`) | `Enter passphrase for key '/Users/alec/.ssh/sshdrive-spike-enc': ` | **unset** |
| keyboard-interactive (`kbd@…:2204`) | `(kbd@192.168.64.1) Password: ` | **unset** |
| host key, empty `known_hosts`, `StrictHostKeyChecking=ask` | `The authenticity of host '[192.168.64.1]:2201 ([192.168.64.1]:2201)' can't be established.\nED25519 key fingerprint is: SHA256:sZBoBnxDlU39oYKVYqzjq1RLWQPpnryr1+EXhXWDt3w\nThis key is not known by any other names.\nAre you sure you want to continue connecting (yes/no/[fingerprint])? ` | **unset** |

`strings /usr/bin/ssh` gives the format strings behind them, and the two we cannot raise
on this VM: `%s@%s's password: `, `Enter passphrase for key '%.100s': `,
`The authenticity of host '%.200s (%s)' can't be established`,
`Are you sure you want to continue connecting (yes/no/[fingerprint])? `,
`Are you sure you want to continue connecting (yes/no)? `,
`Warning: the %s host key for '%.200s' differs from the key for the IP address '%.128s'`,
`Confirm user presence for key %s %s`, `Enter PIN for %s key %s: `, `Enter PIN for '%s': `.

### The §4.2 assumption that failed

**The host-key question does not set `SSH_ASKPASS_PROMPT=confirm`.** §4.2's table and §4.3
both say it does. It arrives with the variable unset, exactly like a password prompt:
`ssh` sets the hint only for `RP_ASK_PERMISSION` ("confirm") and `notify_start` ("none"),
and the host-key question goes through `read_passphrase(prompt, RP_ECHO)`. Classifying on
the hint would have made the agent answer a **stored password** to "Are you sure you want
to continue connecting". The classifier now matches the question's own text first and
treats the hint as corroboration. §4.2, §4.3 and §13 corrected (2026-09-04). Nothing we
raised on this VM produced `confirm` at all; the branch is kept and still refused outside
`add`.

Two smaller ones:

- **`Enter passphrase for key '%.100s'` truncates.** A path over 100 bytes reaches askpass
  cut short, so the prompt text alone cannot be the keychain key. The broker maps the
  prefix onto the asking `ssh`'s own `identityfile` list from the same `ssh -G` resolution
  and keys on the full path (§4.2, §13).
- **A changed host key raises no prompt at all** under `StrictHostKeyChecking=ask`: `ssh`
  prints the REMOTE HOST IDENTIFICATION HAS CHANGED banner and exits, which is the stderr
  path §4.3 already describes. Only an *unknown* host asks.

### An OpenSSH ordering trap, for §6.1

**`-o ProxyJump=none` before `-o ProxyCommand=…` silently discards the ProxyCommand.**
readconf takes the first setting of each keyword and `ProxyJump none` marks the jump host
as set, after which `ProxyCommand` is skipped: the master then tries to resolve the inner
hostname itself and dies with `Could not resolve hostname inner`. With `ProxyCommand`
given **first** and `ProxyJump=none` after, `ssh -G` shows the proxycommand and the chain
works, and a `ProxyJump` in the user's config is still cancelled. §6.1 says to do both but
not in which order; the order is load-bearing.

### What was proved end to end, from the launchd-started agent

Hooks used: `sshdrive debug secrets store|lookup|delete|list|classify|connect`
(documented in `docs/skeleton-notes.md`). Every `connect` spawns a real `/usr/bin/ssh`
from the agent's own environment with `SSH_ASKPASS`, `SSH_ASKPASS_REQUIRE=force` and
`SSHDRIVE_ASKPASS_TOKEN` set, and no tty anywhere.

- **The real keychain from the agent: PASS.** `store` / `lookup` / `delete` / `list`
  against the data-protection keychain, `kSecAttrAccessGroup =
  RWGDZAYBM8.org.shirls.sshdrive`, `kSecUseDataProtectionKeychain = true`,
  `kSecAttrAccessible = kSecAttrAccessibleAfterFirstUnlock`. `list` reports
  `password stored for pw@192.168.64.1` / `passphrase stored for ~/.ssh/sshdrive-spike-enc`,
  which is §4.2's `list`/`show` wording.
- **Password auth through askpass: PASS.**
  `debug secrets connect --destination pw@192.168.64.1 --port 2201` -> `exitStatus 0`,
  `stdout "AUTH-OK-PASSWORD"`, `prompts 1`, `misses []`. The password came from
  `password:pw@192.168.64.1:2201`.
- **Encrypted key through askpass: PASS.** Same hook with
  `--identity ~/.ssh/sshdrive-spike-enc` against `alec@192.168.64.1:2201` ->
  `exitStatus 0`, `stdout "AUTH-OK-PASSPHRASE"`, `prompts 1`, `misses []`, passphrase from
  `passphrase:/Users/alec/.ssh/sshdrive-spike-enc`.
- **A `ProxyJump` hop is keyed by its own host: PASS.** Master to `alec@inner` through the
  agent-built `ProxyCommand` to `hop@192.168.64.1:2210`. Two prompts, **both** answered
  from the keychain with *different* passwords (`password:hop@192.168.64.1:2210` =
  `spike-password-a`, `password:alec@inner:22` = `spike-password`), `exitStatus 0`,
  `stdout "AUTH-OK-CHAIN"`. This is the whole §4.2 hop story working: the hop inherited
  the master's token, and the agent told it apart by the argv the askpass read with
  `sysctl KERN_PROCARGS2` and resolved with `ssh -G`.
- **The host-key question is refused outside `add`: PASS.** A temporary `~/.ssh/config`
  stanza pointing `UserKnownHostsFile` at an empty file (removed again in the same run)
  plus `--host-key-checking ask`: the agent recorded the miss, replied a refusal,
  `ssh` exited 255 with `Host key verification failed.`, and the empty `known_hosts`
  stayed empty (0 bytes). Nothing was written to the user's real `known_hosts`.
- **The token is what authorises: PASS.** `sshdrive-askpass` run by hand with no
  `SSHDRIVE_ASKPASS_TOKEN` exits 1 without contacting the agent; run with a made-up token
  it reaches the agent and gets
  `Error Domain=org.shirls.sshdrive.AgentError Code=2 "unknown token"` and exits 1. The
  second case also proves the listener hands an askpass peer the one-method askpass
  interface (`AskpassService.register`, matched on the peer's `proc_pidpath`).
- **An empty answer skips an identity: PASS** (measured with the logging askpass, not the
  agent). `ssh` offered the encrypted key first, got an empty passphrase, logged
  `no passphrase given, try next key`, moved to `~/.ssh/sshdrive-spike` and authenticated.
  That is §4.2's "the agent answers with an empty passphrase ... and nothing is stopped".

Not covered on this VM: the FIDO user-presence notice and the PIN prompt (no security key
attached), so those two rows of the table are the format strings plus unit tests. The
collect flow's relay to the terminal has unit coverage and no CLI yet - `sshdrive add`
arrives in milestone 3.

Left behind on the VM on purpose, for whoever picks S2 up: keychain items
`password:pw@192.168.64.1:2201`, `passphrase:/Users/alec/.ssh/sshdrive-spike-enc`,
`password:hop@192.168.64.1:2210` and `password:alec@inner:22`. Delete them with
`sshdrive debug secrets delete --key <account>`.

---

## 2026-09-04 (late) - what Finder actually draws: s6-7, s6-8, s6-10, and S1 c2

The owner granted **Screen Recording** and then **Accessibility** to
`/usr/libexec/sshd-keygen-wrapper`, which turns the three drawing questions into ordinary
work: `screencapture -x` produces a 2646x1558 PNG (a 2x Retina capture of a 1323x779-point
display) and `System Events` UI scripting reads and drives Finder's windows. Same VM, same
signed Debug build, two domains `nas` and `nas2`.

### How the captures were taken, for the next person

Two things that do **not** work and cost time:

- `perform action "AXShowMenu"` on a Finder list row: the row exposes only
  `AXShowDefaultUI` / `AXShowAlternateUI`, so this silently does nothing.
- `tell application "System Events" to key down control` + `click at {x, y}`: the synthetic
  click does not carry the modifier and Finder opens nothing.

What works is a real right-click posted with CoreGraphics. A six-line Swift program
(`CGEvent(mouseEventSource:mouseType:.rightMouseDown/.rightMouseUp …).post(tap:
.cghidEventTap)`) at the row's AX `position`, with `Accessibility` granted, opens the
contextual menu; `screencapture -x` then captures it and `key code 53` dismisses it. The
row is located by asking Finder to `select` the file and then taking `first row … whose
selected is true`; matching rows by name does not work, because a Finder list row's static
texts read `missing value`. AX coordinates are points and `CGEvent` takes points, so no
scaling is needed, but the resulting PNG is 2x.

The contextual menu itself is **not readable through AX** (`menu 1 of window 1` of the
Finder process does not exist while it is open), so the entries below are read off the
screenshots.

### s6-7. The built-in entries, pinned versus unpinned - **and "Remove Download" is shown on a kept item**

Three captures in one folder of the mount, all in list view.

**Unpinned, downloaded** (`report-001.txt`):

```
Open
Open With                    >
Remove Download
------
Move to Bin
------
Get Info / Rename / Compress "report-001.txt" / Duplicate / Make Alias / Quick Look
------
Copy / Share...
------
(tag colours) / Tags...
------
Quick Actions                >
[ ] Keep Downloaded
```

**Pinned, downloaded** (`report-000.txt`, `debug policy … eager-keep`): byte-for-byte the
same list, with two differences - the last entry reads `[ ] Don't Keep Downloaded`, and
**`Remove Download` is still there.**

**Unpinned, dataless** (`report-003.txt` after `debug evict`): `Download Now` replaces
`Remove Download`, the row carries the system's cloud-with-arrow badge, and the last entry
is `[ ] Keep Downloaded` again.

So the built-in File Provider entries on 26.4 are exactly two, both in the third slot of
the menu: **`Download Now`** when the item is dataless and **`Remove Download`** when it is
materialized. Which one appears follows `isDownloaded` and nothing else. This is the
picture that goes with the capability measurement earlier today: an item served without
`allowsEvicting` still gets `Remove Download`. §2 and §7.2 are corrected accordingly, and
the `NSExtensionFileProviderAllowsUserControlledEviction` question is now a real decision
for milestone 8 rather than a maybe.

Two incidentals:

- **`Move to Bin` is offered even though `allowsTrashing` is never set.** The contextual
  menu has no `Delete Immediately…`; that entry is in the **File** menu, which for a file in
  the mount reads `… Move to Bin / Delete Immediately… / Eject`. So the deletion path a user
  takes from the contextual menu is `Move to Bin`, and §5.4's alert is what turns it into an
  immediate delete.
- **No decoration.** The kept file's row carries no badge of ours, because we declare no
  `NSFileProviderDecorations`; §7.2's pin badge is still unwritten. The only badge in the
  mount is the system's own dataless cloud.

### s6-8. Top level or submenu? - **top level, last, and only one of the pair**

Our custom actions are drawn **at the very bottom of the contextual menu, below `Quick
Actions`, at the top level** - not inside `Quick Actions`, not inside a submenu named after
the app. Each is drawn with a leading empty checkbox-style glyph, which is how Finder
renders `NSExtensionFileProviderActions` entries. Exactly one of the pair appears, which is
the activation rules working: `Keep Downloaded` on an unkept item, `Don't Keep Downloaded`
on a kept one.

That also settles the worry from this morning's entry. Finder 26.4 does carry strings for a
built-in `Keep Downloaded` (N153.7/N153.8) and a `Kept Downloaded` badge, but it does not
draw them for us: an unpinned item shows exactly **one** `Keep Downloaded`, and the pinned
one shows `Don't Keep Downloaded`, a label that exists only in our Info.plist. So there is
no duplicate-label problem and §7.2 keeps its wording.

### s6-10. Window background and sidebar - **background yes, sidebar no**

**Right-click on the empty area of the window** (no selection):

```
New Folder
------
Get Info
------
View                         >
Use Groups
Sort By                      >
Show View Options
------
[ ] Keep Downloaded
```

So the action is offered on the background too, at the top level, and the item it is
evaluated against is the **folder being shown** - here `Documents/Reports`, unpinned, hence
the pin entry. Nothing about the root container is special; the same is true with the mount
itself open.

**Right-click on the sidebar row** (`SSH Drive - nas`):

```
Open in New Tab
Show "SSH Drive"
Download Now
------
Remove from Sidebar
Get Info
Add to Dock
```

**Our entries are absent from the sidebar menu.** The built-in `Download Now` is there
(the domain root is not materialized), and `Show "SSH Drive"` names the *provider*, not the
domain. So `sshdrive pin <name>` on a whole location has no Finder route; the CLI is it.
§7.2 says so now.

### s3-2 confirmed visually

The sidebar with both domains present reads, under **Locations**:

```
iCloud Drive
SSH Drive - nas2
SSH Drive - nas
chosen-newt
Macintosh HD
AirDrop
Bin
```

which is exactly the `<app display name> - <displayName>` composition measured this
morning, with `displayName` the bare nickname.

### S1 c2. Cancelling a download from Finder's progress UI - **there is no cancel control**

With `debug fault nas --fetch-delay 40000` holding one `fetchContents` open, a `cat` of a
dataless file makes Finder draw a **pie-style progress ring** in the list row (AX: the row
gains a `progress indicator` next to its `image` and `text field`). Hovering the pointer
over it for 1.5 s does not turn it into a stop button, and a left click on its centre does
nothing: `debug transfers` still reports `inFlight 1`, the file stays dataless until the
fault's 40 s elapse, and the agent logs no cancellation. The contextual menu on a
downloading item offers no `Stop`/`Cancel` either.

So on 26.4 there is **no per-item cancel affordance in Finder's list view** for a
third-party provider, and c2's real question - does our `Progress` cancel cleanly - cannot
be asked from there. It stays open, and the honest place to test it is
`NSProgress.cancel()` from a unit or integration test in milestone 3, not Finder.

### State the VM was left in

Fault flags all off, `nas2` removed, `nas` re-created with its 8 files, no pin markers, no
Finder windows open, the helper binaries under `/tmp` deleted. `sshtest` untouched.

---

## 2026-09-04 (evening) - the Finder questions of S3 and S6, from a console session

Same VM (macOS **26.4.1** arm64, 25E253, Xcode 26.4), the signed Debug build from
`scripts/mac-build.sh signed` at `/Applications/SSH Drive.app`, fake-backed domains added
with `sshdrive debug fake add`. This pass differs from the earlier ones in that `alec` is
logged in at the console (`CGSessionCopyCurrentDictionary` reports
`kCGSSessionOnConsoleKey = 1`, no `ScreenIsLocked`), so **Apple Events reach Finder,
TextEdit and Xcode from the ssh session** and the runbook's GUI questions can be driven by
`osascript`.

### What the three routes could and could not do

| Route | Verdict |
|---|---|
| `fileproviderctl evaluate <item>` | **Works, and is the best tool here.** It prints the system's own copy of the item, the evaluated activation rules, the decorations, the capability letters and the content policy. `evaluate <action> <item> <target>` evaluates `NSFileProviderUserInteractions` only, of which we declare none, so it prints an empty interaction set; its error message is a useful catalogue of the valid actions: `Create, Move, MoveOut, MoveIn, Copy, CopyIn, CopyOut, Trash, Delete, Rename, ExcludeFromSync`. |
| `osascript` driving Finder / TextEdit | **Works, no TCC dialog needed.** `kTCCServiceAppleEvents` is already allowed for `/usr/libexec/sshd-keygen-wrapper` in the user TCC database, so Finder and TextEdit scripting ran without prompting anybody. |
| `screencapture -x` | **Blocked, and cannot be unblocked from a terminal.** Every attempt returns `could not create image from display`, and `tccd` logs `Service kTCCServiceScreenCapture does not allow prompting; returning denied` with `responsible=/usr/libexec/sshd-keygen-wrapper`. Routing it through Finder (`tell application "Finder" to do shell script "screencapture …"`) does not change the attribution. Screen Recording is a system-database service, so the owner has to add it by hand in System Settings > Privacy & Security > Screen Recording; it will never prompt. |

Accessibility is denied the same way (`tell application "System Events" to return UI
elements enabled` is `false`), so **no context menu could be opened or read**. Everything
below that talks about a menu is either the system's own evaluation of what applies or
Finder's own localized strings, never a picture of a menu.

### New `sshdrive debug` hooks and one Info.plist fix this pass added

- `debug fault <name> --version-mismatch on|off` - `modifyItem` replies with content and
  metadata versions that are not the ones just written (s3-7). The index keeps the true
  versions; only the reply lies.
- `debug fault <name> --collisions on|off` - every `createItem` fails
  `.filenameCollision`, which is the error §5.5's `lstat`-after-`FAILURE` check will raise
  for real in milestone 4 (s3-4).
- The container enumerator now logs `enumerateItems` and `enumerateChanges` with the
  container identifier, which is the only way to answer s3-3.
- `Apps/FileProvider/Info.plist`: **both action activation rules were dead.** See s6-8.

`swift test` is 33/33.

---

### s3-2. Sidebar label and mount path, `nas` versus `SSH Drive - nas` - **never prefix; the system adds the app name itself**

Three domains at once, `displayName` exactly as given:

```
displayName "nas"                -> ~/Library/CloudStorage/SSHDrive-nas
displayName "nas2"               -> ~/Library/CloudStorage/SSHDrive-nas2
displayName "SSH Drive - nas2"   -> ~/Library/CloudStorage/SSHDrive-SSHDrive-nas2
```

and what Finder itself shows for each (`tell application "Finder" to get displayed name
of …`, which is the sidebar and window-title string):

```
SSHDrive-nas             -> "SSH Drive - nas"
SSHDrive-nas2            -> "SSH Drive - nas2"
SSHDrive-SSHDrive-nas2   -> "SSH Drive - SSH Drive - nas2"
```

So the directory name is `<app name with spaces removed>-<displayName with spaces
removed>` and the label Finder draws is `<app display name> - <displayName>`. The app name
is contributed by the system in both, and a `displayName` of `SSH Drive - nas2` gives
exactly the stutter §2 was worried about. **`displayName` is the bare nickname**, which
settles §2 and §4. (`mdls` disagrees with Finder and reports the raw directory name;
Finder's `displayed name` is the one users see.)

### s3-3. Does the system call `enumerateChanges` on a folder's enumerator when Finder shows it? - **No; it does not even make a container enumerator again**

With the enumerators logging, a Finder window opened on `Documents/Reports` produced
exactly two calls, both `enumerateItems`, one per folder on the way down:

```
enumerateItems container=ECC9E10F-…   (Documents)
enumerateItems container=DF39F98B-…   (Documents/Reports)
```

Navigating away and back, closing the window and reopening it on the same folder, and
creating a file in that folder on the server while the window was open produced **no
further container-enumerator calls at all** - not `enumerateChanges`, not a second
`enumerateItems`. The new file still appeared in the open window within ~20 s, through the
working set. So a folder is listed once, ever, and after that Finder is fed from the
replica.

This settles §6.5: neither of the two fallbacks it hoped for exists. The system gives us
no "this folder is being looked at" signal, so the `viewed` reason can only be armed from
our own `enumerateItems` - which fires once, on first show - and everything after that has
to come from the working set.

### s3-4. What Finder does with `.filenameCollision` - **it never asks the user; the system retries the create for ever**

Two different things happen and they should not be confused.

**A real collision inside Finder never reaches us.** `duplicate` of `run.sh` creates
`run copy.sh`; Finder resolves the name itself before calling the provider.

**A case collision arriving from the server is resolved by the system, silently, on the
replica only.** With `README-renamed.txt` already there, `debug mutate nas create-file
README-RENAMED.TXT` gave:

```
server + index:  README-RENAMED.TXT   README-renamed.txt
the mount:       README-RENAMED.TXT   README-renamed 2.txt
```

The system renamed the *older* item to `README-renamed 2.txt` in its replica and did
**not** report that rename back to us - no `modifyItem`, and the server name is untouched.
So on 26.4 a case collision does not break anything, but the user sees a name the server
does not have, which is the argument for §5.4's `hidden = 2` rather than against it.

**Returning `.filenameCollision` from `createItem` is a retry loop, not a dialog.** With
`debug fault nas --collisions on`, a `printf > collide.txt` from the shell, a Finder "new
folder" and a Finder `duplicate` all reported success to their caller, left the item in
the mount, and made fileproviderd retry the create with a doubling backoff (0 s, 0.04 s,
5 s, 15 s, …) for as long as the fault was set:

```
fileproviderd: ‼️ done executing <J1 ‼️ create-item(… n:"c{5}e.txt" …)
               error:<NSError: FP -1001 "The file already exists in this location.">
```

No alert, no badge, and `enumeratorForPendingItems` stayed **empty** (unlike the
`.serverUnreachable` fault of s4-3, which does populate it). Turning the fault off made
all three creates land on the next retry. So `.filenameCollision` must only ever be
answered when the name will *stop* being taken - §5.5's conflict-copy path, which renames
our own file out of the way - and never as a standing refusal, or it is the `.Trash` loop
again.

### s3-5. `chmod +x` inside the mount - **arrives as `.fileSystemFlags`, and we currently drop it**

```
chmod +x <mount>/Documents/Reports/report-001.txt      # a 644 file
-> modifyItem Documents/Reports/report-001.txt changedFields=0x100   (1 << 8 = .fileSystemFlags)
```

Exactly what §5.4 expects. Two notes:

- `chmod +x` on a file that is **already** mode 755 produces no `modifyItem` at all: the
  only bit the replica carries is the owner-execute one, and it was already set. The
  group and other bits changed locally and went nowhere.
- The skeleton's `modifyItem` ignores `.fileSystemFlags`, so the mode did not reach the
  fake server and the system put the local mode straight back (`ls -l` reads `-rw-------`
  again seconds later). That is milestone 4's work; the spike only had to prove the field
  arrives, and it does.

### s3-6. The delete confirmation without `allowsTrashing` - **Finder deletes, and its wording is fixed**

AppleScript `delete` of an item in the mount schedules an `FPDeleteOperation`, not a trash
operation, completes in milliseconds and removes the file from the replica *and* the fake
server:

```
Finder: Scheduling FPOperation: <FPDeleteOperation: …>
Finder: FPOperation completed:  <FPDeleteOperation: …>
```

No dialog is drawn on the AppleScript path. The dialog a person gets is Finder's own, and
its exact wording is in `Finder.app/Contents/Resources/en.lproj/LocalizableMerged.strings`:

```
MT16_V1  Are you sure you want to delete “^1”?
MT16_V2  Are you sure you want to delete the ^0 selected items?
MT18_V1  This item will be deleted immediately. You can’t undo this action.
MT18_V2  ^0 items will be deleted immediately. You can’t undo this action.
AL7      Delete
```

So §5.4's "will be deleted immediately, are you sure?" is right in substance and can now
be quoted exactly. `NSFileProviderItem.h` also documents a switch we did not know about:
`NSExtensionFileProviderAllowsSystemDeleteAlerts = 0` in the appex Info.plist suppresses
the system's own delete warnings for a provider that wants to draw its own. We want the
system's, so we leave it alone.

### s3-7. `modifyItem` returning a version that differs from the upload - **the system believes us; it neither re-fetches nor re-offers**

With `debug fault nas --version-mismatch on`, one append to a materialized file gave
exactly one `modifyItem` (`changedFields=0x81`, contents + contentModificationDate), the
agent replied with `127-1788457968-0-fault` instead of `127-1788457968-0`, and then:

```
debug stat        blocks 8   dataless false   size 127
evaluate          isDownloaded 1   isMostRecentVersionDownloaded 1   hasUnresolvedConflicts 0
                  versionIdentifier = "127-1788457968-0-fault"
debug transfers   total 0        # no fetchContents, then or later
```

No second `modifyItem`, no re-fetch when the file was read again, no conflict flag. The
system simply records whatever version the reply carries.

**This contradicts §5.5.** Its conflict policy rests on "the system re-fetches that content
and does not re-offer the local edit"; only the second half is true. Returning the remote
item from a conflicting `modifyItem` leaves the replica holding the *local* bytes under
the *remote* version, and nothing will ever correct it. The fix is small and is now in
§5.5: after returning the remote item, the agent calls
`NSFileProviderManager.evictItem` on that identifier, which s4-1 proved works, so the next
open downloads the remote content. The same finding makes the post-upload `lstat` of §5.5
load-bearing for a second reason: a version we invent is a version the next sweep will not
recognise.

### s3-8. Atomic saves - **TextEdit and a shell temp+rename are both one `modifyItem` on the original identifier**

TextEdit, driven by AppleScript (`open`, `set text of document 1`, `save`, `close`):

```
modifyItem Documents/Reports/report-003.txt changedFields=0x8     (lastUsedDate, on open)
modifyItem Documents/Reports                changedFields=0x80    (the parent's mtime)
modifyItem Documents/Reports/report-003.txt changedFields=0x289   xattrKeys=com.apple.TextEncoding
```

`0x289` = contents | lastUsedDate | contentModificationDate | extendedAttributes. The item
identifier before and after is the same `7768EB02-…`. **No `createItem`, no `deleteItem`.**

The classic shell form of the same dance - write a temp file beside the target and `mv`
over it - behaves identically:

```
printf … > Documents/Reports/.tmp-005 ; mv .tmp-005 report-005.txt
-> modifyItem Documents/Reports            changedFields=0x80
   modifyItem …/report-005.txt             changedFields=0xc1
   identifier 5284601D-… unchanged, content is the new content
```

So the no-tombstones risk of §5.3 does not bite for these two. **Xcode: not exercised.**
Xcode 26.4 is installed and scriptable enough to open the file and set its text, but its
`source document` does not implement `save` (`-1708`), and there is no way to send it a
Cmd-S without Accessibility. **Pages, Numbers, Keynote and Microsoft Office are not
installed on this VM**, so their saves remain untested.

### s6-7. Which built-in menu entries Finder shows, and whether dropping `allowsEvicting` removes "Remove Download" - **partly answered, and the answer is that dropping it does nothing**

What can be measured without a screen is what the system thinks the item's capabilities
are, which is what Finder draws from. `fileproviderctl evaluate` prints them twice, as a
number and as a letter string whose sixth slot is `allowsEvicting`:

| item | row served by us | system's capabilities | letters |
|---|---|---|---|
| unpinned file, dataless | 111 (`e` set) | 0x2000002F | `rwdpf-t-----` |
| unpinned file, downloaded | 111 (`e` set) | 0x2000006F | `rwdpfet-----` |
| **pinned file, downloaded** | **47 (`e` cleared)** | **0x2000006F** | **`rwdpfet-----`** |
| pinned folder, downloaded | 47 (`e` cleared) | 0x2400006F | `rwdpfet-----` |
| root container, pinned | 47 (`e` cleared) | 0x2400006F | `rwdpfet-----` |

The pinned rows were read back four times over forty seconds and never changed, and the
same snapshot's `userInfo.kept` was `1`, so the system had certainly re-read the item.
**The system puts `allowsEvicting` back.** What it does track is `isDownloaded`: a dataless
item loses the bit, a materialized one has it, whatever we serve.

So §2's "an item whose `capabilities` omit `allowsEvicting` is not offered Remove Download
at all" and §7.2's second belt are both wrong on 26.4. The header agrees that the
capability is the wrong lever - it is `API_DEPRECATED("use NSFileProviderContentPolicy
instead", macos(11.0, 13.0))` - and names the one that works, per provider rather than per
item: `NSExtensionFileProviderAllowsUserControlledEviction = false` in the appex's
`NSExtension` dictionary, which "suppress[es] the user's ability to evict the item in the
UI but retain[s] the ability of the OS or the provider's program to evict items". The
neighbouring key `NSExtensionFileProviderAllowsContextualMenuDownloadEntry = 0` removes
Finder's "Download Now" the same way. Neither is set today.

The guarantee itself is unaffected: s6-5 already showed the eager `contentPolicy` is what
refuses an eviction, and it still does.

**Still needs a screen:** the actual list of entries Finder draws. Two things found in
`LocalizableMerged.strings` make that worth doing rather than assuming, because Finder
26.4 has a *built-in* keep-downloaded feature we did not know about:

```
N153.3    Download Now
N153.4_V1 Remove Download        N153.4_V2 Remove Downloads
N153.7_V1 Keep Downloaded        N153.8_V1 Keep Downloaded
NE88.2.1  Downloaded   NE88.3.1 Not Downloaded   NE88.3.2 Kept Downloaded
AXBADGE12 Kept downloaded
```

Our own action is also called "Keep Downloaded" (§7.2), so if Finder draws its own for a
third-party provider the menu has two entries with one label. Note that our items report
`isKeepDownloaded = 0` even when their effective content policy is
`downloadEagerlyAndKeepDownloaded` (3), so that flag is the system's own and is not driven
by our policy - which is a hint, not a proof, that the built-in entry is not offered to us.

### s6-8. Do our custom actions appear at the top level or in a submenu? - **not answerable without a screen, but both rules were dead and are now fixed**

The precondition turned out to be broken. `fileproviderctl evaluate` on any item printed:

```
org.shirls.sshdrive.action.pin: SUBQUERY(fileProviderItems, $item, $item.userInfo.kept == 0).@count
  == $fileProviderItems.@count - Can't get value for 'fileProviderItems' in bindings {}.
```

Two mistakes in one string:

1. **The bound key is `fileproviderItems`, lower-case p.** The object `fileproviderctl`
   evaluates against is a dictionary whose only key is spelled that way, and
   `fileProviderItems` with a capital P **does not occur anywhere in the dyld shared
   cache** - `strings` over `dyld_shared_cache_arm64e.*` finds exactly one standalone
   occurrence of the key and it is the lower-case one. Apple's own documentation uses the
   capital spelling.
2. **It is a key path, not a substitution variable.** `$fileProviderItems` raises
   `NSInvalidArgumentException` out of `-[NSVariableExpression expressionValueWithObject:]`
   because the bindings dictionary is empty, and the whole rule is dropped.

Either mistake alone silently removes the entry, with nothing in any log. Rewritten to
§7.2's "at least one" form with the right key, they evaluate:

```
unpinned item     pin YES   unpin NO
pinned item       pin NO    unpin YES
```

Recorded while we were there, because it decides between §7.2's form and the "all selected
items" one: `SUBQUERY(k, …).@count == k.@count` is `0 == nil-count`, i.e. **true**, when the
key is absent or the selection is empty, so the "all" form would light up both entries on
an empty selection. §7.2's `.@count > 0` form is false there, which is another reason to
keep it.

Where Finder puts the two entries once they are live still needs a screen.

### s6-10. Do the actions appear on the window background and the sidebar entry? - **the root container matches the rule; where Finder draws it still needs a screen**

`fileproviderctl evaluate <mount directory>` is exactly the "root as the selected item"
case, and it behaves like any other item:

```
root unpinned:  kept = 0   pin YES   unpin NO
root pinned:    kept = 1   pin NO    unpin YES   Content Policy 3
```

So nothing about the root container excludes it from the activation rules, and §7.1.2's
"the root is not a special case" holds here too. Whether Finder offers a provider's custom
actions on a window background with no selection, or on the sidebar row, is a drawing
question no terminal can answer. One thing the evaluator does say about the empty case:
with §7.2's `> 0` rules, an empty `fileproviderItems` matches neither entry.

### Also recorded

- **Decorations are empty** for every item, as expected: we declare no
  `NSFileProviderDecorations`. §7.2's pin badge is still unwritten.
- **A Finder rename** is one `modifyItem` with `changedFields=0x2` (`.filename`), which
  finishes s3-1's rename half.
- `fileproviderctl evaluate <action>` evaluates `NSFileProviderUserInteractions`, a
  different Info.plist key from `NSExtensionFileProviderActions`, and one worth knowing
  about: it is how a provider puts its own confirmation alert (title, subtitle, buttons,
  help URL, suppression) in front of a Move, Trash, Delete, Rename or Create. Nothing in
  milestone 1 needs it; §5.5's conflict copy and §5.4's delete might in milestone 4.
- **S1 c2 (cancelling a large download from Finder's progress UI)** was not attempted: it
  needs a pointer on the progress popover, so it stays a screen question.

### State the VM was left in

The signed Debug build at `/Applications/SSH Drive.app` (rebuilt and reinstalled twice
during this pass), agent running from launchd, `sshdrive doctor` green apart from the two
expected warnings, **one** fake location `nas` mounted at `~/Library/CloudStorage/SSHDrive-nas`,
no pin markers, all four faults off (`debug fault nas` reports `writesFail false`,
`createsCollide false`, `versionMismatch false`, `fetchDelayMilliseconds 0`). The `nas2`
and `SSH Drive - nas2` domains from s3-2 were removed. No Finder windows left open.
`sshtest`'s state was not touched.

### What to do next on the VM

1. The three drawing questions, in front of a screen: s6-7's actual entry list, s6-8's
   top-level-versus-submenu, s6-10's window background and sidebar, and S1 c2. All four
   need either Screen Recording added for `/usr/libexec/sshd-keygen-wrapper` in System
   Settings (it will never prompt) or somebody looking at the screen.
2. Decide, before milestone 8, whether to set
   `NSExtensionFileProviderAllowsUserControlledEviction = false`; s6-7 says the capability
   alone does nothing.
3. Still open from the entries below: re-run s4-2 and s4-5 on macOS 14 or 15, the
   `useReader` hook for s3-14, and a Developer ID plus `notarytool` pass for S1(d4).

---

## 2026-09-04 - S4 and S6 on the headless Mac VM (eviction, atime, pinning)

Every headless-feasible sub-question of S4 and S6, in runbook order. Same VM (macOS
**26.4.1** arm64, 25E253, Xcode 26.4, no GUI), the signed Debug build from
`scripts/mac-build.sh signed` installed at `/Applications/SSH Drive.app`, the appex
carrying `com.apple.developer.fileprovider.testing-mode`, one fake-backed domain `nas`.
Note the OS: the design asks about 14 and 15 in two places and this is 26.4, so every
answer below is "on 26.4" until someone runs it on 14.

The three Finder-menu questions - **s6-7, s6-8, s6-10** - are **needs-Finder** and were
not attempted: they are about what Finder draws, and no terminal can see that.

### New `sshdrive debug` hooks this pass added

`evict`, `materialized [--pending]`, `stat [--read]`, `xattr`, `fault [--writes]
[--fetch-delay]`, `transfers [--reset]`, `stabilize`, `testing`, `signal --container`,
and `fake add --testing-modes`. `debug policy` now creates the missing ancestor rows
first. All of them are documented in `docs/skeleton-notes.md`; `swift test` is 33/33.

Two behaviours of the harness worth knowing before the next pass:

- **`scripts/mac-build.sh` syncs with `rsync -a --delete`,** so any mode wipes `build/`
  on the Mac. Running `test` after `signed` deletes the app you were about to install.
  Build with `signed` last.
- **`waitForStabilization` is not a barrier for downloads.** It returns in well under a
  second and only says the two sides have exchanged what they know. The
  `com.apple.fileproviderd.background-download` scheduler is separate and, on an idle
  headless Mac, takes anything from 8 s to 90 s to start an eager fetch. Every timing
  below is "after stabilization plus that wait".

---

### s4-1. Does `evictItem` work for files in our domain? - **Yes, and for directories and the root too**

```
$ sshdrive debug evict nas README.txt
{ "evicted" : true, "allowsEvictingServed" : true, "kept" : false, ... }
$ sshdrive debug stat nas README.txt
  "blocks" : 0,   "dataless" : true,   "size" : 37
```

The file went dataless and kept its size, its xattrs and its atime.

**The design's folder rule is wrong on this OS.** `evictItem` on
`Documents/Reports` returned `evicted: true` and left every file under it dataless, and
`evictItem` on `.rootContainer` emptied the whole location: the materialized set went
from 11 items to **0**, directories included. `NSFileProviderManager.h` documents exactly
that ("When called on a directory, first each of the directory's children will be
evicted ... Then the directory itself will be made dataless"), with
`NSFileProviderErrorNonEvictableChildren` reserved for the case where a child refuses.
So §7 step 2's "skip directories; folder eviction is known to fail" and CLAUDE.md's
"Folder eviction fails; evict files only" are both out of date, and `sshdrive evict
--all` is one call on the root rather than a walk.

One incidental: **an eviction moves atime**, so the loop must read atime before it
evicts, not after. It already does.

### s4-2. Does atime advance on every read, only when older than mtime, or never? - **Only when older than mtime**

The relatime rule, and it is the whole macOS/APFS rule rather than anything File
Provider does. On a materialized file whose atime is already newer than its mtime, ten
`cat`s over forty seconds moved nothing:

```
materialized:      atime=1788454141 mtime=1788453962  wall=1788454140
idle 20s:          atime=1788454141 mtime=1788453962  wall=1788454160
after 5 reads:     atime=1788454141 mtime=1788453962  wall=1788454160
after 5 more:      atime=1788454141 mtime=1788453962  wall=1788454180
```

Force atime below mtime and the very next read advances it to now:

```
atime just before mtime:  atime=1788453961 mtime=1788453962
read;  wall=1788454123     atime=1788454123 mtime=1788453962
atime just after mtime:   atime=1788453963 mtime=1788453962
read;  wall=1788454123     atime=1788453963 mtime=1788453962   # unmoved
```

A plain file on `/tmp` on the same Mac behaves identically (atime 1788454300 > mtime
1788453000, two reads, unmoved), so this is not the replica being special.

Two things do move atime: **materializing** the file (the fetch sets it to now), and
**evicting** it. And the domain's own Spotlight indexer reads files, which is one of the
"we accept it as used" cases §7 already lists - it produced one unexplained advance
during this pass.

So the second of §7's two meanings is the one in force: **the TTL is time since the last
fetch or save**, `last_fetch` and mtime carry it, and atime adds nothing a materialized
file does not already have. §7 anticipated this; `sshdrive show` and the docs must state
it.

### s4-3. Does the system refuse to evict an item with pending changes? - **Yes**

With `sshdrive debug fault nas --writes on` every upload fails `.serverUnreachable`, so
an `echo >>` in the mount leaves the item in the system's pending set:

```
$ sshdrive debug materialized nas --pending
  "count" : 1,  "path" : "Documents/Reports/report-004.txt"
$ sshdrive debug evict nas Documents/Reports/report-004.txt
  "errorDomain" : "NSFileProviderErrorDomain",
  "errorCode" : -2008,
  "errorDescription" : "The file 'report-004.txt' cannot be evicted."
```

So §7 step 3 holds: the eviction loop needs no pending-upload check of its own.

**But the code is not the documented one.** -2008 is
`NSFileProviderErrorNonEvictable`, the "provider marked it non-purgeable" code;
`NSFileProviderErrorUnsyncedEdits` is -2007 and never appeared. A kept item refuses with
the same -2008 (s6-5), so **the loop cannot tell a pin from a pending upload by error
code** and must not read -2008 as either. Evicting the *parent directory* of the pending
item fails differently again, and opaquely:

```
  "errorDomain" : "NSCocoaErrorDomain",  "errorCode" : 4101,
  "errorDescription" : "Couldn't communicate with a helper application.",
  "underlyingErrors" : [ { "errorDomain" : "libfssync.VFSFileTree.ItemNotFoundReason",
      "errorCode" : 5,
      "errorDescription" : "contentVersionMismatch(55207874@3:sz:151, expected: ...@2:sz:140)" } ]
```

not the `NSFileProviderErrorNonEvictableChildren` (-2006) the header promises. A
directory evict is therefore worth doing for `evict --all`, but its failure must be
logged and moved past, never interpreted.

### s4-4. Do Finder tags and other xattrs survive eviction? - **Other xattrs yes; tags never arrive as xattrs at all**

Eviction is safe. All three xattrs written through the mount were still on the file
after `evictItem` made it dataless, which is what `NSFileProviderItem.extendedAttributes`
promises in as many words: "The system will set extended attributes on dataless files,
and will preserve them when a file is rendered dataless. I.e extended attributes are
considered metadata, not content."

```
$ xattr -l .../report-005.txt          # after evictItem, blocks=0, dataless=true
com.apple.metadata:_kMDItemUserTags: bplistfake-Red
org.sshdrive.spike: s4-4
org.sshdrive.spike2#S: syncable-value
```

Two findings §5.4 does not have, both from watching what `modifyItem` actually received:

- **The system decides which xattrs the extension ever sees.** Of the three above, only
  `org.sshdrive.spike2#S` - the name carrying `XATTR_FLAG_SYNCABLE` - arrived in
  `changedFields.extendedAttributes` and reached the index. `org.sshdrive.spike`, an
  ordinary name, never did: it lives in the replica and the extension is never told. The
  header names `NSExtensionFileProviderAdditionalSyncableExtendedAttributes` in the
  appex's Info.plist as the way to widen that set.
- **Finder tags do not come through `extendedAttributes` at all.**
  `com.apple.metadata:_kMDItemUserTags` and `com.apple.FinderInfo` are excluded
  deliberately, "because that would be redundant": tags reach a provider as the item's
  own `tagData` property. And they are **not preserved across a re-download** - after
  re-materializing the file the two `org.sshdrive.*` xattrs were still there and the tags
  xattr was gone, because our item carries no `tagData` for the system to restore it
  from.

So §5.4's "Finder tags, colours, `FinderInfo` ... are stored in the index row and
returned on every item" is right in intent and wrong in mechanism, and as written it
loses the user's tags on the first remote change. Corrected there; the round-trip half is
S10's to prove.

### s4-5. Does a launchd agent's `stat` under `~/Library/CloudStorage` draw a TCC prompt? - **No prompt, no `EPERM`**

Dozens of `lstat`s and `open`s of the replica from the launchd-started agent over this
pass, every one successful; no `statErrno`, no `openErrno`. `tccd` does evaluate them,
and the interesting part is which service it uses:

```
AUTHREQ_CTX: msgID=158.287, service=kTCCServiceSystemPolicyAllFiles, preflight=yes
AUTHREQ_ATTRIBUTION: accessing={identifier=org.shirls.sshdrive, pid=86265, auid=501,
    binary_path=/Applications/SSH Drive.app/Contents/MacOS/SSH Drive},
  requesting={identifier=com.apple.sandboxd}
AUTHREQ_RESULT: msgID=158.287, authValue=0, authReason=5      # denied: no Full Disk Access
... TCCCreateDesignatedRequirementIdentityFromAuditTokenForService service=kTCCServiceFileProviderDomain
... TCCCreateIndirectObjectIdentityForFileProviderDomainFromPath
    kTCCCodeIdentityIdentifier = "org.shirls.sshdrive";
    kTCCIndirectObjectFileProviderDomainID = "org.shirls.sshdrive..."
... TCCAccessRequestIndirect service=kTCCServiceFileProviderDomain -> REPLY (501)
```

The agent is denied `kTCCServiceSystemPolicyAllFiles`, which it does not need, and the
access is then evaluated as `kTCCServiceFileProviderDomain` with **our own domain as the
indirect object** and allowed with no prompt and no `Prompting` line anywhere in the log.
A provider reaching its own domain's mount is not gated. So §7's "a prompt a launchd
agent cannot answer would come back as a silent EPERM" is a contingency that does not
arise here, and `sshdrive doctor` needs no line for it - on 26.4. It is still worth a
re-run on 14 before the claim is made unconditional.

---

### s6-12. Is `contentPolicy = .inherited` the neutral value? - **Yes**

Taken first, because it is the baseline every other S6 answer is measured against. Every
unpinned item is served `.inherited` (the extension maps our "unset" to it). On a freshly
added domain with the root enumerated once, the materialized set holds one item - the
root - and `debug transfers` shows **0 fetches**, indefinitely. `.inherited` forces
nothing.

### s6-1. Does an eager policy download the whole subtree after a working-set signal? - **Yes**

`sshdrive debug policy nas Documents eager-keep`, one working-set signal, then ~10 s:

```
$ sshdrive debug materialized nas
  "count" : 11        # /, Documents, Documents/Reports, report-000..007
$ sshdrive debug transfers nas
  "peakConcurrent" : 5,   "total" : 8
```

Eight files down through our own `fetchContents`, exactly as §7.1 step 2 expects.

### s6-2. Does it enumerate subfolders never opened in Finder? - **Yes**

`Documents/Reports` had **no row in the index and had never been listed by anyone** when
the pin was set - `fake add` enumerates only the root. The system asked for it,
our container enumerator listed it, and its eight files came down in the same pass. The
offline claim in §7.1 stands.

### s6-3. Does it accept a chain of never-enumerated ancestors reported through the working set? - **Not on its own; the chain has to be looked up**

This is the one answer that changes a design step, and it was reproduced three times.

Building `Deep/a/b/{one,two}.txt` on the fake server without letting anything list it,
then `debug policy nas Deep/a/b eager-keep` (which readdirs `Deep` and `Deep/a` into the
index, writes an anchor for each and signals the working set, i.e. exactly §7.1 step 1):

```
--- working-set signal only ---
t=+30s  "total" : 0,  "count" : 2
t=+60s  "total" : 0,  "count" : 2
t=+90s  "total" : 0,  "count" : 2
--- then signalEnumerator on each new ancestor's own container ---
t=+30s  "total" : 0,  "count" : 2
t=+60s  "total" : 0,  "count" : 2
t=+90s  "total" : 0,  "count" : 2
--- then one `ls` of the pinned folder in the mount ---
t=+30s  "total" : 0,  "count" : 5
t=+60s  "total" : 2,  "count" : 7      # one.txt and two.txt downloaded
```

Reporting the ancestors through the working set is not enough, and neither is
`signalEnumerator(for:)` on each of them. What starts it is a **lookup of the path in the
replica**. The good news is that the agent can make that lookup itself, without a user,
a Finder or a shell: on a second chain, `getUserVisibleURL` for the pinned row followed
by one `lstat` - `sshdrive debug stat nas Deep2/x/y`, 0.46 s, the file still dataless -
was enough, and `Deep2/x/y/f1.txt` came down within 90 s. s4-5 is what makes that legal:
the agent may read its own domain's mount with no TCC prompt.

§7.1 step 1 is corrected to say so. Without it `sshdrive pin` on a path Finder has never
shown would write the markers, report them, and quietly download nothing.

### s6-4. Do new remote files under a pin get fetched on the next poll? - **Yes**

```
$ sshdrive debug mutate nas create-file Documents/Reports/new.txt --contents hello-from-the-server
$ sshdrive debug stabilize nas       # 0.84 s
   ... 8 s later
$ sshdrive debug materialized nas | grep new.txt
      "path" : "Documents/Reports/new.txt"
$ cat ~/Library/CloudStorage/SSHDrive-nas/Documents/Reports/new.txt
hello-from-the-server
```

The eager policy applies to children that appear after it was set, which is §7.1 step 3.

### s6-5. Does `evictItem` refuse a kept item? - **Yes, and the policy is what refuses, not the capability**

```
$ sshdrive debug evict nas Documents                        # the pin root
  "kept" : true, "allowsEvictingServed" : false, "errorCode" : -2008,
  "errorDescription" : "The folder 'Documents' cannot be evicted."
$ sshdrive debug evict nas Documents/Reports/report-000.txt  # merely inherits the pin
  "kept" : false, "allowsEvictingServed" : true,  "errorCode" : -2008,
  "errorDescription" : "The file 'report-000.txt' cannot be evicted."
$ sshdrive debug evict nas README.txt                        # unpinned control
  "evicted" : true
```

The middle case is the finding. That file's row still carried `allowsEvicting` and
`kept = false` - milestone 1's `debug policy` writes the marker on one row only - and the
system refused it anyway, because its **effective `contentPolicy`, inherited from the
eager ancestor, is what makes an item non-evictable.** `allowsEvicting` is also
`API_DEPRECATED("use NSFileProviderContentPolicy instead", macos(11.0, 13.0))`, and the
header adds a third lever we did not know about:
`NSExtensionFileProviderAllowsUserControlledEviction = false` in the appex's Info.plist,
which "suppress[es] the user's ability to evict the item in the UI but retain[s] the
ability of the OS or the provider's program to evict items". §7.2 is corrected: the eager
policy carries the guarantee, dropping `allowsEvicting` is belt-and-braces on a
deprecated key, and whether the Finder entry actually disappears is still s6-7's to
record.

### s6-6. Does an explicit `.downloadLazily` on a child override an eager ancestor? - **Yes**

`Documents/Reports` marked `excluded` (`pin_state = -1`, served as `.downloadLazily`),
then `Documents` marked `pinned`. After stabilization and a signal:

```
  "count" : 4,   "path" : "",  "Documents",  "Documents/Reports",  "Documents/top.txt"
  "peakConcurrent" : 1,   "total" : 1
```

One fetch: the sibling `Documents/top.txt` directly under the eager folder. All nine
files inside the excluded `Documents/Reports` stayed dataless. Exclusions work, so
§7.1.1's five-situation table has the mechanism it assumes.

(This needed the snapshot to serve a real `.downloadLazily` for `pin_state = -1`; it used
to serve "no opinion", under which the eager ancestor would simply have won. Fixed in
`IndexItemSnapshot.swift`, with a test.)

### s6-7, s6-8, s6-10 - **needs-Finder**

Which built-in menu entries Finder shows for kept and unkept items, whether dropping
`allowsEvicting` removes "Remove Download", whether our two custom actions land at the
top level or in a submenu, and what a right-click on the window background or the sidebar
entry offers. Not attempted. `fileproviderctl evaluate <item>` exists and is worth
recording next to what Finder draws, but it answers a different question.

### s6-9. Does an eager policy on `.rootContainer` download the whole location? - **Yes**

```
$ sshdrive debug policy nas / eager-keep
  "identifier" : "NSFileProviderRootContainerItemIdentifier", "kept" : true
   ... two minutes later
$ sshdrive debug materialized nas
  "count" : 20      # every directory, all 8 reports, README.txt and run.sh
```

The root is not a special case, which is what §7.1.2 assumed and no longer has to hedge.

### s6-11. How many `fetchContents` calls does the system keep open at once? - **Six**

Measured with `sshdrive debug fault nas --fetch-delay 5000`, which holds each fetch open
for 5 s so the overlap is real rather than inferred, over a 30-file eager subtree:

```
peak 6   total 38
start times, rounded to 0.5 s:
  0.0 x6   5.5 x6   10.5 x6   16.0 x6   21.0 x6   60.0 x6   65.0 x2
max overlap recomputed from the timeline: 6
```

Strict batches of six, never seven, for 38 transfers. The undelayed runs peaked at 5.
So the bound §6.2 wanted is **6 concurrent `fetchContents` per domain**, and the
scheduler's own limit of four sits comfortably under it: at most six XPC calls are ever
held.

---

### The testing-mode entitlement, in practice

`NSFileProviderManager.listAvailableTestingOperations` / `run(_:)` are reachable (the
profile's `com.apple.developer.fileprovider.testing-mode` is live) but only on a domain
added with `NSFileProviderDomainTestingModeInteractive`, which `debug fake add
--testing-modes interactive` now sets. **None of the answers above needed it**, and it
was left off: interactive mode "disable[s] the automatic scheduling from the system",
which is precisely the behaviour S6 is measuring, and the header warns the mode cannot be
removed from a domain once given. What did the work instead was `waitForStabilization`
plus `waitForChanges(below:)` (`debug stabilize`) for the metadata side, and patience for
the download scheduler. `fileproviderctl` on 26.4 has no scheduling verbs at all - only
`dump`, `diagnose`, `evaluate`, `check`/`repair` and `obfuscate`.

### State the VM was left in

The signed Debug build at `/Applications/SSH Drive.app`, agent running from launchd,
`sshdrive doctor` green apart from the two expected warnings, one fake location `nas`
(`5DFFD268-...`) mounted with 41 items materialized, no faults set (`--writes off`,
`--fetch-delay 0`), no pin markers left. `sshtest`'s state is untouched.

### What to do next on the VM

1. s6-7, s6-8, s6-10 in front of a screen, together with S3's Finder questions.
2. Re-run s4-2 and s4-5 on macOS 14 or 15 before either answer is written down
   unconditionally.
3. Still open from the entries below: the `useReader` hook for s3-14, and a Developer ID
   plus `notarytool` pass for S1(d4).

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
