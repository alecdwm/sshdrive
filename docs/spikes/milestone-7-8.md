# Milestones 7 and 8: eviction and pinning

Runbook for the two milestones DESIGN.md section 12 numbers 7 (the TTL loop, `evict`,
`set cache-ttl`) and 8 (`pin`/`unpin`/`pins`, the content policy, kept-subtree watching,
the Finder actions and the badge). The spikes they rest on - **S4** and **S6** - were
answered in milestone 1; this file is the steps, the answer the design expects, and a
**Result** line for what actually happened. The long-form entry is in `results.md` under
"2026-09-05 (milestones 7 and 8)".

Everything runs on the headless Mac VM (macOS 26.4.1 arm64, Xcode 26.4) against the Docker
testbed on the Mac that hosts it, over ssh.

| Tag | Meaning |
|---|---|
| **VM** | the headless VM plus the testbed. Everything below is this unless marked otherwise. |
| **unit** | a package test, run by `swift test`. |
| **mount** | needs the signed build installed and a real File Provider domain. |
| **screen** | needs Screen Recording *and* Accessibility granted to `/usr/libexec/sshd-keygen-wrapper`, as `results.md` (2026-09-04, late) records. |

---

## 0. Setup

### 0.1 Build and install

From the Linux side:

```
scripts/mac-build.sh test       # 548 package tests
scripts/mac-build.sh signed
```

**`mac-build.sh` rsyncs with `--delete` and `build/` does not exist on the Linux side, so
every run deletes the Mac's build directory.** Run `signed` *last*.

On the Mac VM:

```sh
"/Applications/SSH Drive.app/Contents/MacOS/sshdrive" agent stop
ditto "$HOME/sshdrive/build/Build/Products/Debug/SSH Drive.app" "/Applications/SSH Drive.app"
"/Applications/SSH Drive.app/Contents/MacOS/sshdrive" agent start
```

### 0.2 macOS has no `timeout`, and no `ls` of a mount may go without one

Same rule as every earlier milestone. `~/bin/timeout` is the six-line perl
`fork`/`alarm`/`exec` from `milestone-5.md` 0.2.

### 0.3 The tree and the location

`deb` (2201) only: pinning and eviction are the system's behaviour, not the server's, so
one GNU-`find` server is enough.

```sh
ssh -i ~/.ssh/sshdrive-spike -p 2201 alec@192.168.64.1 '
  rm -rf ~/m78; mkdir -p ~/m78/keep/sub ~/m78/keep/raw ~/m78/loose
  for f in a b c; do head -c 2000 /dev/urandom | base64 > ~/m78/keep/$f.txt; done
  head -c 3000 /dev/urandom | base64 > ~/m78/keep/sub/deep.txt
  head -c 1000 /dev/urandom | base64 > ~/m78/keep/sub/deep2.txt
  head -c 4000 /dev/urandom | base64 > ~/m78/keep/raw/big.txt
  for f in fresh stale edit other; do head -c 1500 /dev/urandom | base64 > ~/m78/loose/$f.txt; done'

sshdrive add m78 alec@192.168.64.1:2201 --identity ~/.ssh/sshdrive-spike \
        --path /home/alec/m78 --cache-ttl 15m
```

### 0.4 The one hook these milestones needed

**`sshdrive debug ttl <name> --seconds N`** sets the cache TTL in seconds for this agent
process only. Section 7's shortest real value is `15m`, and a runbook that waited a quarter
of an hour per assertion would be run once and never again. The override changes the number
the rule is applied to and nothing else - the pass, the `stat`s, the `evictItem`s and every
skip are the ordinary ones - which is the same bargain `debug watch --clock-skew` makes for
the sweep window. `--off` puts the location's own `cache-ttl` back.

The rest of the hooks are milestone 1's and unchanged: `debug materialized [--pending]`,
`debug stat`, `debug evict`, `debug fault --writes`, `debug index dump`, `debug policy`.

---

## 1. The TTL evicts a fetched file, and not one touched since

*Section 7 steps 1-3: every five minutes, last use = max(mtime, `last_fetch`), evict what
is older than the TTL.*

```sh
M=~/Library/CloudStorage/SSHDrive-m78
timeout 30 cat "$M/loose/stale.txt" > /dev/null      # both materialize
timeout 30 cat "$M/loose/fresh.txt" > /dev/null
sshdrive debug ttl m78 --seconds 30
sleep 35
printf 'touched again\n' >> "$M/loose/fresh.txt"     # a save counts as use
sshdrive evict m78                                   # the same pass, on demand
sshdrive debug stat m78 loose/stale.txt | grep dataless
sshdrive debug stat m78 loose/fresh.txt | grep dataless
```

Expected: `stale.txt` goes dataless, `fresh.txt` does not.

**Result: passes.**

```
m78: TTL 30s (debug override)   4 KB in 2 file(s) cached
  dropped 1, kept 0 pinned, in 0.13s
loose/stale.txt   "dataless" : true,     "blocks" : 0
loose/fresh.txt   "dataless" : false,    "blocks" : 8
```

A **save** is what saved `fresh.txt`, not a read: section 7's TTL is time since the last
fetch or save, and a `cat` of an already-materialized file is neither. See §6 below for the
atime measurement that made this the whole rule.

---

## 2. The five-minute timer fires by itself

*Section 6.6: the loop runs on a timer, not only when the CLI asks.*

```sh
timeout 30 cat "$M/loose/other.txt" > /dev/null
timeout 30 cat "$M/loose/stale.txt" > /dev/null
sshdrive debug ttl m78 --seconds 60
# then poll `sshdrive debug materialized m78` every 20 s and touch nothing else
```

Expected: with no `sshdrive evict` at all, the files go dataless within five minutes of the
agent's last pass.

**Result: passes.** Agent started 01:00:32, files fetched 01:00:35, TTL 60 s; the
materialized set went from 11 rows to 8 (the eight directories) at **01:05:36**, one
`CacheEvictor.interval` after the loop started, and `status` then read
`cache 0 bytes materialized (0 files)   TTL 15m   next eviction pass in 4m`.

The first pass is deliberately one interval after the location comes up rather than at
startup: a location that has just mounted has just been listed and the agent has nothing to
measure yet.

---

## 3. A pending edit is never evicted

*Section 7 step 3: "the system refuses to evict an item with unsynced local changes, so
pending uploads need no check of ours" (S4).*

```sh
timeout 30 cat "$M/loose/edit.txt" > /dev/null
sshdrive debug fault m78 --writes on            # every upload fails .serverUnreachable
printf 'a local edit that cannot reach the server\n' >> "$M/loose/edit.txt"
sshdrive debug materialized m78 --pending
sshdrive debug ttl m78 --seconds 1
sshdrive evict m78
```

**Result: passes.** The pending set held exactly `loose/edit.txt`; the pass tried it,
was refused, logged it and moved on, and evicted the other file in the same pass:

```
  "count" : 1,   "path" : "loose\/edit.txt"
m78: TTL 1s (debug override)   4 KB in 2 file(s) cached
  dropped 1, kept 0 pinned, in 0.68s
  refused loose/edit.txt: The file ‘edit.txt‘ cannot be evicted.
loose/edit.txt   "dataless" : false,   "blocks" : 8
```

`debug fault --writes off` and the edit flushed; the pending set went back to 0. The refusal
is `NSFileProviderErrorNonEvictable` (-2008), which says nothing about *why* (S4), so the
loop reads nothing into it.

---

## 4. `evict --all` empties the materialized set

*Section 7 step 4, and S4's "one call on the root container rather than a walk".*

```sh
for f in a b c; do timeout 30 cat "$M/keep/$f.txt" > /dev/null; done
timeout 30 cat "$M/loose/other.txt" > /dev/null
timeout 30 cat "$M/loose/stale.txt" > /dev/null
sshdrive debug materialized m78 | grep '"count"'    # 9
sshdrive evict m78 --all
```

**Result: passes.** 9 materialized items to **0**, directories included, from one
`evictItem` on `.rootContainer`:

```
m78: everything cached was dropped.
  "count" : 0,
```

### 4.1 With a pin in place, and straight after `--unpin-all`

On a second location (`m78b`, four files, `keep` pinned and downloaded):

```
$ sshdrive evict m78b --all
m78b: dropped 1 file(s); 3 kept file(s) were left alone (pass --unpin-all to drop those too).
$ sshdrive evict m78b --all --unpin-all
Removed 1 pin(s) first.
m78b: dropped 3 file(s).
materialized rows: 2        # the two directory rows
```

**Result: passes, after two goes at it.** The first attempt used the one root-container call
whenever the markers were empty *after* the unpin, and it failed:

```
m78b: the system refused: The file couldn’t be opened.
```

`NSCocoaErrorDomain`, no reason named. The system has not yet re-read the rows whose policy
the unpin just changed, and the container will not go while any child is still eager.
Measured with `debug evict` in a loop: **a single file becomes evictable 5-10 s after the
unpin, and the root container did not within a minute.** So `--all` uses the one call only
when nothing is *or has just been* pinned, and otherwise walks the materialized set with
section 5.5's doubling backoff per file. The cost of the walk is that the directory rows
stay materialized, which is the loop's own rule (a TTL is per file).

`--all` on a location with a pin left in place evicts what is not kept and says how many it
left; the counts skip directories and local-only rows rather than calling them "kept".

A single path, and a kept one:

```
$ sshdrive evict m78b loose.txt
Dropped loose.txt from m78b.
$ sshdrive evict m78b keep/a.txt
Error: keep/a.txt is kept downloaded. Run `sshdrive unpin` on it first, or
`sshdrive evict --all --unpin-all` to drop every pin.
```

The refusal is ours, with a sentence: the eager policy would refuse the call anyway (S6) and
-2008 names no reason.

---

## 5. `pin` on a folder nothing has opened downloads the whole subtree

*Section 7.1 steps 1-2, and S6's "including folders nothing has ever listed".*

`keep/sub` had a row (its parent had been listed) but had never been enumerated: nothing in
the index below it.

```sh
sshdrive pin m78 keep
# poll `sshdrive debug materialized m78`
```

**Result: passes, in about 60 s.**

```
Pinned keep.
  pinned; 9 item(s) updated.
t=+50s materialized rows: 4
t=+60s materialized rows: 10     # /, keep, a,b,c, raw, raw/big, sub, sub/deep, sub/deep2
```

Every file under the pin came down, including the two in the never-enumerated `keep/sub`.
The "9 item(s) updated" is section 7.1 step 2's descendant rewrite: the changed row plus
every known descendant, each with its metadata version moved and an anchor written, in one
transaction.

### 5.1 A path nothing has ever listed, ancestors and all

```sh
ssh … 'mkdir -p ~/m78/never/x/y && … > ~/m78/never/x/y/one.txt … two.txt'
sshdrive pin m78 never/x/y          # `never` and `never/x` have no rows at all
```

**Result: passes.** `pin` `readdir`ed `never` and `never/x` into the index, signalled the
working set, and then made S6's **replica lookup** - `getUserVisibleURL` plus one `lstat` -
which is what makes the system ingest the chain. Both files were downloaded:

```
never/x/y                        pinned    2 KB, 2 of 2 file(s) downloaded
```

Without that last step the markers would be written, reported, and nothing downloaded
(S6, 2026-09-04, s6-3). It is one call and under a second on a dataless item.

---

## 6. A new remote file under a pin is fetched

*Section 7.1 step 3: pin roots are always in the change-detection root set, watched
recursively.*

```sh
ssh … 'printf "made-on-the-server\n" > ~/m78/keep/sub/arrived.txt'
# poll, with `sshdrive status m78` between polls so the location counts as touched (6.4)
timeout 20 cat "$M/keep/sub/arrived.txt"
```

**Result: passes, inside a minute.** The tier 1 sweep found it, the row was created
**already kept** (its parent row carries the effective state, section 7.1's "descendants the
index has never seen need nothing"), the eager policy fetched it, and the mount served
`made-on-the-server` with no network round trip of the user's.

---

## 7. An exclusion under a pin stays lazy, and the TTL takes it

*Section 7.1.1, situation C: `unpin` on an item that merely inherits a pin records an
exclusion, and "the eviction loop uses the kept state, so an excluded file inside a kept
folder is evicted like any other cached file".*

```sh
sshdrive unpin m78 keep/raw
sshdrive pins m78
sshdrive debug ttl m78 --seconds 1
sshdrive evict m78
```

**Result: passes.**

```
Unpinned keep/raw.
  excluded from the pin above it; the content stays and falls under the TTL; 2 item(s) updated.

keep                             pinned    19 KB, 7 of 7 file(s) downloaded
  keep/raw                       excluded  (5 KB on the server, 1 file(s) downloaded)

m78: TTL 1s (debug override)   21 KB in 9 file(s) cached
  dropped 1, kept 8 pinned, in 0.13s
```

The one file dropped was `keep/raw/big.txt`; the eight kept files were skipped by us, not
refused by the system. A minute later `big.txt` was **still dataless**: the explicit
`.downloadLazily` overrides the eager ancestor, so the policy does not fetch it back.

The index says the same thing, which is the inheritance rule in one table:

```
keep                 kept=True  pin= 1 caps=47
keep/a.txt           kept=True  pin= 0 caps=47
keep/raw             kept=False pin=-1 caps=111
keep/raw/big.txt     kept=False pin= 0 caps=111
keep/sub/arrived.txt kept=True  pin= 0 caps=47      # created after the pin
```

`caps` 47 versus 111 is the `allowsEvicting` bit (64) dropped on a kept item. It is not what
refuses the eviction - the eager `contentPolicy` is (S6) - but it is part of the metadata
version and has to agree with the marker.

---

## 8. `pins` lists them

**Result: passes** (see the trees above). Exclusions are indented under the pin they sit in,
with the cached size and file count section 7.1 asks for. `--export` writes the markers as
JSON and `--import FILE` reads them back:

```
$ sshdrive pins m78 --export > /tmp/m78-pins.json
$ sshdrive unpin m78 keep            # clears the pin and, by invariant 2, the exclusion
$ sshdrive pins m78
No pins in m78. …
$ sshdrive pins m78 --import /tmp/m78-pins.json
Imported 2 marker(s) into m78.
keep                             pinned    14 KB, 6 of 7 file(s) downloaded
  keep/raw                       excluded  (5 KB on the server, 0 file(s) downloaded)
```

The CLI reads the file, not the agent: the CLI is the process with the user's working
directory and their read permission. Markers are applied shortest path first, so the pin is
written before the exclusion invariant 2 would otherwise wipe.

`pins.json` beside the index is written on every marker change and is never read while the
index is healthy; `IndexReconcile` reads it during a rebuild and then re-derives `kept` over
the whole table, since a restored marker's *effect* is not restored with it.

---

## 9. Pinning the whole location

*Section 7.1.2: the root is an item like any other.*

```sh
sshdrive pin m78 /
```

**Result: passes.** By invariant 2 this cleared the two nested pins and the exclusion, and
every file in the location came down:

```
  pinned; 12 item(s) updated.
/                                pinned    16 KB, 8 of 13 file(s) downloaded
t=+75s materialized rows: 21       # 8 directories + all 13 files
```

`sshdrive pins` renders the root as `/`, and `sshdrive pin m78 .` names the same thing.
There is no Finder route to it (section 10.3), which is what section 7.1.2 already says.

---

## 10. The Finder entries **screen**

*Section 7.2. The capture recipe is `results.md`, 2026-09-04 (late): a real right-click
posted with CoreGraphics at the row's AX position, `screencapture -x`, `key code 53` to
dismiss.*

Two things are new this pass and worth keeping:

- **The file list is `outline 1 of scroll area 1 of splitter group 1 of splitter group 1`.**
  `splitter group 1` alone is the *sidebar*. A list row's name now reads from
  `value of text field 1 of UI element 1 of the row` (it was `missing value` in September's
  capture), so a row can be found by name again.
- **Our entry can be *invoked* without knowing where it is.** It is always the last item in
  the contextual menu, so `key code 126` (up arrow, which wraps to the bottom) followed by
  `key code 36` (return) picks it. The menu itself is still not readable through AX.

### 10.1 On a selected file - **passes**

Right-click on `keep/a.txt`, unkept and downloaded:

```
Open / Open With > / Remove Download / --- / Move to Bin / --- / Get Info / Rename /
Compress / Duplicate / Make Alias / Quick Look / --- / Copy / Share… / --- / (tags) /
Tags… / --- / Quick Actions > / [ ] Keep Downloaded
```

Up + Return, and four seconds later:

```
$ sshdrive pins m78
keep/a.txt                       pinned    3 KB, 1 of 1 file(s) downloaded
```

Right-click it again and the same menu now ends `[ ] Don't Keep Downloaded`, with
`Remove Download` still in the third slot - the pair toggles by `userInfo.kept` and Finder's
own entry follows `isDownloaded` and nothing else, exactly as S6 recorded. Up + Return again
and `sshdrive pins m78` is empty.

### 10.2 On the window background - **passes**

Right-click the empty area of the `keep` window:

```
New Folder / --- / Get Info / --- / View > / Use Groups / Sort By > / Show View Options /
--- / [ ] Keep Downloaded
```

Up + Return, and the item it acted on is the folder being shown:

```
$ sshdrive pins m78
keep                             pinned    19 KB, 7 of 7 file(s) downloaded
```

### 10.3 The sidebar row

Not re-tested; S6 recorded on 2026-09-04 that our entries are absent there, and nothing in
milestone 8 changes what Finder draws. The CLI is the only route to pinning a whole
location, which is where section 7.1.2 puts it anyway.

### 10.4 The badge - **passes, and it is not where the header implies**

`NSFileProviderDecorations` in the appex's `NSExtension` dictionary, one entry with
`Identifier` = `org.shirls.sshdrive.decoration.kept`, `BadgeImageType` =
`com.apple.icon-decoration.badge.pinned`, `Category` = `Badge`, `Label` = "Kept downloaded
by SSH Drive"; `Item.decorations` returns it for every row whose `kept` is 1.

Finder 26.4 draws an **orange disc with a white push-pin at the trailing edge of the Name
column** in list view - not on the item's icon, which is what `Category: Badge`'s "on top of
the icon" suggests. Every kept row carries it, inherited ones included; an excluded folder
inside a kept one carries none.

Three traps, all silent, are now in section 7.2: the four keys are the bare
`Identifier`/`BadgeImageType`/`Label`/`Category` from `NSFileProviderItemDecoration.h`;
`BadgeImageType` is a UTI conforming to `com.apple.icon-decoration.badge` and not an asset
name (the system ships `.badge.pinned`, `.checkmark`, `.locked`, `.syncing`, `.warning` and
more in `CoreTypes.bundle`, so no icon asset of ours is needed); and `Category` is `Badge`,
since `FolderBadge` embosses and is folders-only.

---

## 11. `unpin`, and then the TTL takes the subtree

```sh
sshdrive unpin m78 keep
sshdrive debug ttl m78 --seconds 1
sshdrive evict m78
```

**Result: passes.**

```
Unpinned keep.
  pin removed; the content stays and falls under the TTL; 10 item(s) updated.
m78: TTL 1s (debug override)   30 KB in 13 file(s) cached
  dropped 13, kept 0 pinned, in 1.62s
```

Every file in the location went dataless; the eight directory rows stayed materialized,
because the loop is file by file - a TTL is per file, and a directory holds no content.

---

## 12. `set cache-ttl`, and what `status` says

```
$ sshdrive set m78 cache-ttl 12h
m78: cache-ttl is now 12h
$ sshdrive status m78
m78   alec@192.168.64.1:2201   mounted   online   TTL 12h
       cache 16 KB materialized (7 files), 14 KB kept   TTL 12h   next eviction pass in 5m
       pins  keep   !keep/raw   (a leading ! is an exclusion; sshdrive pins m78 shows the tree)
```

**Result: passes.** The change takes effect without a restart (the setting drops and
re-creates the runtime, and the new evictor reads the new value; `applyCacheTTL` covers an
unmounted location). Section 8.1's Cache line carries the four numbers it asks for and the
time to the next pass.

---

## 13. What was not tested, and why

- **Section 7.2's re-assert safety net.** It fires when a *kept* file turns dataless without
  our handler having run, and there is no route to make that happen: Finder's "Remove
  Download" on a kept item is refused by the eager policy (S6), and so is `evictItem` from
  the agent. The code path is written, has its own state (`keptAndMaterialized`, only files
  the agent has *seen* materialized count) and stays dormant, which is what section 7.2
  predicts. `status` carries the count when it ever does fire.
- **A TTL longer than a few minutes**, for the obvious reason; the rule is proved against an
  injected clock in `EvictionPlanTests` and the loop's own arithmetic is the same code.
- **macOS 14 and 15.** Every answer here is on 26.4.1, like every earlier milestone's.
- **The sidebar row** (10.3) and **tier 2**, which is milestone 9.

---

## 14. Leaving the VM clean

```sh
sshdrive remove m78 --yes
ssh -i ~/.ssh/sshdrive-spike -p 2201 alec@192.168.64.1 'rm -rf ~/m78'
rm -rf ~/m78-tools ~/m78-shots /tmp/m78-pins.json
```

`sshdrive remove` takes the domain, the index and the keychain items only it names; the
mount directory goes with the domain.
