# Milestone 6 spike: S7, change detection tiers 0 and 1

Runbook for the spike DESIGN.md section 12 folds into milestone 6. Section 11's S7 row has
the questions; this file has the steps, the answer the design expects, and a **Result**
line for what actually happened. The long-form entry is in `results.md` under
"2026-09-04 (milestone 6)".

**The helper half of S7 is not here.** Tier 2 is milestone 9, so the helper's coexistence
with two SFTP channels, its kqueue behaviour on FreeBSD and its 100,000-file sweep are all
out of scope; `auto` tops out at sweep and every question below is about tiers 0 and 1.

Everything runs on the headless Mac VM against the Docker testbed on the Mac that hosts it,
over ssh.

| Tag | Meaning |
|---|---|
| **VM** | the headless VM plus the testbed. Everything below is this unless marked otherwise. |
| **unit** | a package test, run by `swift test`; the testbed-backed ones need `SSHDRIVE_TESTBED=1`. |
| **mount** | needs the signed build installed and a real File Provider domain. |

---

## 0. Setup

### 0.1 Build and install

From the Linux side:

```
scripts/mac-build.sh test       # 503 package tests
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

`sshdrive` has no `version` subcommand; `agent start` prints the agent and interface
versions and is what starts it.

### 0.2 macOS has no `timeout`, and no `ls` of a mount may go without one

Same rule as every earlier milestone: put a deadline on every `ssh` and never `ls` a mount
bare. `~/bin/timeout` is the six-line perl `fork`/`alarm`/`exec` from `milestone-5.md` 0.2.

### 0.3 The servers this spike needs

| Server | Port | Why |
|---|---|---|
| `deb` | 2201 | GNU `find` with `-cmin` and `-printf`; the 15,011-file `data/` tree; `ClientAliveInterval 15/3` |
| `deb-shells` | 2202 | every login-shell shape, `bashbg`, `forcesftp`, and **`ClientAliveInterval` unset** |
| `deb-extsftp` | 2203 | external `sftp-server` behind a noisy shell |
| `alp` | 2206 | busybox `find`: no `-cmin`, no `-printf` |
| `alp-nocmin` | 2208 | the same, with the redundant shim |

### 0.4 The big tree

S7 asks for the `-cmin` sweep timed "on a 1M-file tree with 200 roots". The README's
scaling knobs (`SEED_TREE_DIRS`, `SEED_TREE_FILES`) need the `deb` service recreated from
the Mac, which this session could not do without disturbing the seeded `data/` tree every
other spike depends on. So the big tree was seeded **over ssh, beside it**:

```sh
ssh -i ~/.ssh/sshdrive-spike -p 2201 alec@192.168.64.1 'cat > ~/seedbig.pl' <<'PL'
use strict; use warnings;
my $root = $ENV{HOME}.'/bigtree';
my ($dirs, $files) = (2000, 500);
mkdir $root;
for my $d (0..$dirs-1) {
  my $p = sprintf('%s/d%04d', $root, $d);
  mkdir $p or next;
  for my $f (0..$files-1) { open(my $fh, '>', sprintf('%s/f%03d.bin', $p, $f)) or die $!; close $fh; }
}
PL
ssh … 'perl ~/seedbig.pl'
```

**Result: 2,000 directories x 500 empty files = 1,000,000 files, seeded in 11 s**, 13 GB
still free on `/home`. `find ~/bigtree -type f | wc -l` = 1000000. Delete it when the
spike is done: `ssh … 'rm -rf ~/bigtree ~/seedbig.pl ~/seedbig.log ~/seedbig.start ~/seedbig.end'`.

---

## 1. Tier 1 over an exec channel, beside SFTP traffic on one connection

*S7: "does a long-running helper stream coexist with two SFTP channels on one connection".
The helper is milestone 9; the sweep is what tier 1 runs on that channel.*

**unit** `TestbedSweepTests.testSweepCoexistsWithTwoSFTPChannelsOnOneConnection`: one
master, two `SFTPChannel`s each carrying a real `RealSFTPTransport`, a task that keeps
`readdir`ing on both, and a sweep of the 15,011-file `data/` tree on an exec channel at the
same time.

Expected: three channels at once on one `-N` master; the sweep finishes; both SFTP channels
serve listings *during* it and still work afterwards.

**Result: passes.** The sweep returned 15,275 hits, both channels served listings while it
ran and both answered an `lstat` afterwards, and the master was still up. The whole test is
0.54 s, which is itself the answer to "is one connection enough": a sweep of 15,000 files
is a fraction of a second of channel time, so tier 1 does not contend for the connection in
any way a user would notice.

---

## 2. How long the `-cmin` sweep takes on the largest tree the knobs reach

*S7: "how long does the `find -cmin` sweep take on a 1M-file tree with 200 roots".*

Run server-side, from the account's home, with the exact expression section 6.4 specifies.
Two passes, so the second is warm; a container on the same Mac cannot have its page cache
dropped, so **these are a floor, not a NAS**.

```sh
PF='%p\0%y\0%s\0%T@\0%i\0%m\0%U\0%G\0'
ROOTS=$(ls -d bigtree/d0* | head -200)
find $ROOTS \( -type d -o -type f \) -cmin -60 -printf "$PF" | wc -c
find bigtree \( -type d -o -type f \) -cmin -1  -printf "$PF" | wc -c
```

**Result** (Debian 12, GNU findutils, 1,000,000 files in 2,000 directories):

| Shape | Cold-ish | Warm | Output |
|---|---|---|---|
| 200 roots, recursive, `-cmin -60 -printf`, everything matches | 376 ms | 175 ms | 7,213,200 B (100,200 records) |
| 200 roots, `-maxdepth 1`, same | 181 ms | 174 ms | the same set: the roots are leaf directories |
| whole 1M tree, `-cmin -60 -printf`, everything matches | 2,946 ms | 1,673 ms | 72,132,061 B |
| whole 1M tree, `-cmin -1`, **nothing** matches | 858 ms | 886 ms | 0 B |
| whole 1M tree, `-cmin -2` after one `touch` | — | **876 ms** | one record |
| whole 1M tree, unbounded + `-printf` (a full sweep on GNU) | 3,001 ms | 1,635 ms | 72,132,061 B |
| whole 1M tree, unbounded + `-print0` (a full sweep elsewhere) | 228 ms | 204 ms | 23,028,008 B |

So **the ordinary incremental sweep of a 1M-file tree is under a second** and returns one
record. The number to know is that `-cmin` costs a `stat` per entry: the same walk with
`-print0` and no time test is 204 ms, and adding either `-cmin` or `-printf` takes it to
850-1,650 ms. A NAS with a spinning disk and a cold cache will be far worse, which is what
the 30-minute insurance sweep and the poll cadence are sized for, not this.

**argv, against section 6.4's 64 KB batching:** 200 roots is 2,799 bytes and 2,000 roots is
28,000 bytes, so the batch limit does not bite until roughly 4,600 roots at these name
lengths. The batching is still right - a photo library's `materialized` set can pass that -
but it is not the common case, and `SweepPlanTests` is where it is proven rather than here.

---

## 3. `-cmin` / `-printf` across GNU and busybox, and the `-mmin` fallback

*S7: "Check `-cmin` and `-printf` across GNU, BSD and busybox `find`". There is no BSD in
the testbed (Docker shares the Linux kernel); that half still needs a FreeBSD box.*

```sh
find data -maxdepth 0 -cmin -60      # busybox: find: unrecognized: -cmin, rc=1
find data -maxdepth 0 -printf '%p'   # busybox: find: unrecognized: -printf, rc=1
find data -maxdepth 0 -mmin -60      # rc=0
touch /tmp/s; find data -newer /tmp/s  # rc=0
```

**Result, identical on `alp` (2206) and `alp-nocmin` (2208), BusyBox v1.36.1:** `-cmin`
rejected, `-printf` rejected, `-mmin` and `-newer FILE` accepted. `find --version` prints
`find: unrecognized: --version` **and exits 0**, so the probe's flavour test cannot use the
exit status; it uses the `busybox` banner and the `-cmin` answer, which it already did.

`alp-nocmin`'s shim adds nothing over stock busybox and is not a separate case, exactly as
`testbed/README.md` now says.

**The cost of the fallback, measured rather than asserted.** On busybox, with a file whose
mtime was set back to 2020 and then `chmod`ed:

```
after create, -mmin -1 hits: 1
after chmod with an old mtime, -mmin -1 hits: 0
```

and the same probe on GNU `deb` finds it with `-cmin` and misses it with `-mmin`
(**unit** `TestbedSweepTests.testCminCatchesAChmodThatMminMisses`, passes). So the loss
section 6.4 predicts is real and is exactly one class: a change that moves ctime and not
mtime. `status` carries it as a normal line on every busybox server.

**unit** `TestbedSweepTests.testBusyboxSweepRunsWithMminAndBarePaths` also proves the
belt-and-braces rule in `SweepPlan`: a plan built with `flavour: .busybox` refuses `-cmin`
and `-printf` **even when the probe says they are available**, because a busybox `-cmin`
does not lose a field, it fails the whole sweep with nothing on stdout.

---

## 4. The server-clock sweep window against skew

*S7: "the server-clock sweep window against a server whose clock is five minutes behind".*

**A container cannot have its clock skewed.** Docker has no time namespace and every
container shares the host's clock, so there is no way to make `deb` five minutes behind.
Shifting the *VM's* clock instead would move the Mac's clock, which is the one thing the
design says the window must not depend on, so it would prove nothing.

So the sweep's own reference is skewed by a hook, and this is said plainly rather than
claimed as a clock test: `sshdrive debug watch <name> --clock-skew <seconds>` shifts **the
stored server timestamp** the next window is computed from, and `sshdrive status` prints
`note: the sweep's server-clock reference is shifted by Ns by a debug hook` for as long as
it is set. What that exercises is the arithmetic and the "store only after applying" rule;
what it cannot exercise is a real server whose `date +%s` disagrees with ours.

```sh
sshdrive debug watch m6 --clock-skew -300 --now    # the reference 5 minutes behind
sshdrive debug watch m6 --clock-skew 300  --now    # and 5 minutes ahead
sshdrive debug watch m6 --forget-stamp --full      # no stamp at all: an unbounded sweep
sshdrive debug watch m6 --clock-skew 0
```

Expected: behind -> a wider window and duplicate hits, which are harmless because the
result is diffed anyway; ahead -> `SweepWindow.clockWentBackwards` and a window clamped to
one minute, never zero or negative; no stamp -> the time test is dropped from the `find`
expression entirely.

**Result:** building the hook found a real error in the first implementation, and it is
the error section 6.4 warns about. The window was computed as `serverNow - stored` with
`serverNow` taken from the **Mac's** wall clock, which folds the entire clock difference
into the window: a server five minutes behind would have been swept with a window of
nothing at all. The window is now **elapsed time on our clock applied to the server's
stamp** - the local time at which the server stamp was stored is kept beside it, and `N` is
`ceil((now - thatLocalTime) / 60) + 1` - so neither clock's absolute value enters into it.
The arithmetic is covered by `SweepWindowTests` (in `SweepPlanTests.swift`) against injected values, and the plumbing -
that the stored value is the one the **script** printed and not the Mac's clock - by
**unit** `TestbedSweepTests.testGnuSweepCarriesTheServerClockAndFullRecords`, which asserts
the returned `serverTime` against the Mac's clock only as a sanity bound and takes it from
the script's own `date +%s` record.

The other half of the rule is tested where it belongs: **the timestamp is stored only after
the results have been applied.** `RemoteSweep` returns `serverTime: nil` for a truncated
sweep and `ChangeDetector` writes nothing in that case, so a sweep that was cut off leaves
the next window covering everything it missed.

---

## 5. The `sh -s` mechanism under every login shell

*S7: "the `sh -s` stdin-script mechanism under bash, zsh, fish and csh login shells, each
with an rc file that prints to stdout, confirming the sentinel discards it ... plus an rc
file that leaves a background child holding stdout, confirming the closing sentinel returns
the snapshot before the timeout."*

These were answered in milestone 2 and are re-run here because tier 1 rides on them.

**unit**, all against `deb-shells` (2202):

| Test | Accounts | Result |
|---|---|---|
| `TestbedShellTests.testSentinelDiscardsRcOutputOnEveryLoginShell` | `bashnoisy` `bashbg` `zshuser` `fishuser` `tcshuser` `dashuser` | passes; every account's own output survives its rc noise, and every one but `dashuser` really does print noise |
| `TestbedShellTests.testBashbgDoesNotHangTheReader` | `bashbg` | passes in under 25 s: the sentinel, not EOF, ends the read |
| `TestbedShellTests.testLoginShellSnapshotCommandUnderEveryShell` | all six | passes; the **closing** sentinel returns the snapshot before the timeout even on `bashbg`, and fish's `PATH` is still colon-separated because the snapshot uses `env -0` |
| `TestbedShellTests.testAwkwardNamesSurviveSetDashDash` | `bashnoisy` | passes; `$(echo pwned)`, `quote'name`, `space in name`, `back\slash`, `*star*` |
| `TestbedSweepTests.testSweepReturnsOnABashbgAccountWhereEOFNeverArrives` | `bashbg` | passes; a whole **sweep** returns on the closing sentinel, not at the timeout |
| `TestbedSweepTests.testAwkwardRootsAndAwkwardOutputSurviveTheSweep` | `alec@deb` | passes; six awkward directory names used as **sweep roots**, each hit returned, and no `pwned` file created |

---

## 6. Abrupt client kill: does a bare background process survive?

*S7: "Kill the client abruptly with `ClientAliveInterval` unset on the server and record
whether a bare background process survives, and whether the heartbeat wrapper kills it
within a minute."*

Two halves. The **control** is a bare `sleep &` started by the session that is then
`SIGKILL`ed, with no wrapper at all:

```sh
ssh -i ~/.ssh/sshdrive-spike -p 2202 bashnoisy@192.168.64.1 sh -s <<'EOF' &
sleep 42001 &
sleep 900
EOF
kill -9 $!        # the client, abruptly
# then count `sleep 42001` in /proc every 20 s for three minutes
```

**Result: the bare sleeper survived 180 s on every server tried, including the one with
`ClientAliveInterval` set.**

| Server | `ClientAliveInterval` | bare child at t+180 s |
|---|---|---|
| `deb-shells` (2202) | unset | **alive** |
| `deb` (2201) | 15 / 3 | **alive** |
| `alp` (2206, busybox) | unset | **alive** |

That is sharper than section 6.4 says. The section explains the danger in terms of
`ClientAliveInterval` being unset - "a connection that died under a sleeping laptop is
noticed only when TCP gives up, hours later" - which reads as though setting it would fix
the problem. It does not: sshd reaping the session does not reach a child that has left the
foreground job, so the child outlives the connection **whatever `ClientAliveInterval` is**.
The heartbeat wrapper is not a workaround for a common misconfiguration; it is the only
thing that ever kills what we started. Section 13 records it.

The **wrapper** half is the milestone 2 tests, re-run:

| Test | Server | Branch | Result |
|---|---|---|---|
| `TestbedHeartbeatTests.testHeartbeatWrapperOnDebianWhereShIsDash` | `deb` | `sleep`+mtime watchdog (`/bin/sh` is dash) | passes: child gone inside 75 s |
| `…OnAlpineBusybox` | `alp` | `read -t` | passes |
| `…UnderADashLoginShell` | `deb-shells`/`dashuser` | watchdog | passes |
| `…testSilenceAloneKillsTheChildEvenWithTheChannelOpen` | `deb` | silence, not EOF | passes |

---

## 7. The external `sftp-server` account and the `ForceCommand` account

*S7: "Run the probe against an account whose login shell prints on startup and whose sshd
uses an external `sftp-server`, confirming the exec-channel `sftp-server` fallback, and
against a `ForceCommand internal-sftp` account, confirming it is reported as no shell
rather than unusable output."*

**unit** `SFTPIntegrationTests` (the `extnoisy` / `extquiet` cases on `deb-extsftp`, 2203)
and `TestbedShellTests.testForceCommandAccountIsReportedAsNoShellAccess` (`forcesftp` on
2202).

Expected: `extnoisy`'s subsystem answers with rc output in front of the SFTP `VERSION`, so
the client opens SFTP on an exec channel that prints the sentinel and then `exec`s the
`sftp-server` binary the probe located; `forcesftp` is reported as **"no shell access
(ForceCommand)"**, never "shell output unusable".

**Result: both pass**, unchanged from milestone 2. The `ForceCommand` case is worth
repeating because it is the one that decides a location's tier: an account reported as
"unusable shell output" would be a bug report about an rc file, while "no shell access" is
correctly a poll-only location, and `status` says so.

---

## 8. A tier 0 cycle with as many `materialized`-only roots as the rotation can be given

*S7: "Measure a tier 0 cycle with 5,000 `materialized`-only roots under the rotation."*

Section 6.5's rotation is the thing under test: every `viewed` and `pinned` root is listed
every cycle, and **at most 64 `materialized`-only roots** are taken round-robin in order of
least recent listing, so a directory holding only cached files is refreshed every
`ceil(M / 64)` cycles and the cost per cycle is bounded whatever `M` is.

Five thousand directories were made on `deb` (`~/m6roots/d0000..d4999`), a location added
on them, the root enumerated so every directory has a row, and the `materialized` reason
put on all five thousand with `sshdrive debug roots m6b --seed 5000`. **Only the reason is
injected**: every one of those directories exists and is really `readdir`ed by the cycle.
Materializing a file in each of five thousand directories to get the reason honestly is
five thousand downloads, and what section 6.5's rotation is measured on is the cost of a
cycle at that scale, not how the roots got there. The hook also suppresses the
materialized refresh for that location, or the next cycle would take the reason straight
back off again - the system reports none of them materialized, quite correctly.

```sh
sshdrive add m6b alec@192.168.64.1:2201 --identity ~/.ssh/sshdrive-spike --path /home/alec/m6roots
ls ~/Library/CloudStorage/SSHDrive-m6b >/dev/null      # every directory gets a row
sshdrive set m6b watch-mode poll
sshdrive debug roots m6b --seed 5000
sshdrive debug watch m6b --now      # one cycle under the rotation
sshdrive debug watch m6b --full     # one cycle with the rotation suspended
```

**Result: 5,000 `materialized`-only roots reached, which is S7's figure.**

| | Directories listed | Time |
|---|---|---|
| one tier 0 cycle under the rotation | **65** (64 materialized-only + the root, which is `viewed`) | **0.91 s** |
| the next cycle | 65 again, the next 64 in least-recent-listing order | — |
| one **full** cycle, rotation suspended | **5,001** | **16.69 s** |

`rotationPeriod` is 79, which is `ceil(5000 / 64)`, and `status` says
`5001 root(s) rotating over 79 cycles`. So the rotation is worth about **eighteen times**
on this set: without it, a location holding five thousand cached directories would spend
16.7 s of every 60 s listing them, which is not proportional to anything the user is
looking at - exactly the case section 6.5 describes. With it the cost per cycle is bounded
whatever `M` is, and a directory holding only cached files is refreshed every 79 cycles.

The rotation's rules themselves are proven exhaustively in **unit** `RootSetTests` against
injected clocks: the 64-per-cycle cap, least-recent-listing order, `ceil(M/64)`, the 256
`viewed` cap and its LRU eviction, and the pin-root exclusion. What the mount adds is the
wall-clock cost.

---

## 9. The mount proofs

**mount**. The runs below were driven by a throwaway harness on the VM, since removed; the
commands it issued are the ones written out here. Two locations:

```sh
sshdrive add m6  alec@192.168.64.1:2201 --identity ~/.ssh/sshdrive-spike --path /home/alec/m6
sshdrive add m6a alec@192.168.64.1:2206 --identity ~/.ssh/sshdrive-spike --path /home/alec/m6a
```

### 9.1 Create, modify, rename, delete on the server

A **separate** ssh makes each change; the mount is then polled until it shows it. `deb` runs
the GNU `-cmin` sweep and `alp` the busybox `-mmin` fallback.

**Poll the mount and you also have to touch the location.** `test -e` inside the mount is
answered from the system's replica and never reaches the extension - a folder is enumerated
once, ever (section 6.5) - so a run that only polls the mount is not "active" by section
6.4's rule and falls to the ten-minute cadence after ten minutes. The first attempt at this
proof did exactly that and its last three steps timed out at 150 s. A CLI command naming the
location **is** a touch, so the harness issues one every 20 s; that is what a person watching
a mount from a terminal does.

**Result: every step inside one poll interval, on both servers.**

| Step | `m6` (`deb`, GNU `-cmin -printf`) | `m6a` (`alp`, busybox `-mmin`) |
|---|---|---|
| `created.txt` appears | 59,743 ms | 60,687 ms |
| its content changes | 104 ms | 117 ms |
| `renamed.txt` appears | 59,923 ms | 59,406 ms |
| `created.txt` vanishes | 7 ms | 4 ms |
| `renamed.txt` vanishes | 59,647 ms | 60,122 ms |

The pattern is the cadence, not the mechanism: a change is found by the next 60-second
cycle, and everything that cycle finds arrives together, which is why the second and fourth
rows are milliseconds. The busybox column is the same because a create, a write, a rename
and a delete all move mtime; the one thing `-mmin` misses is a ctime-only change, which is
section 3 above.

### 9.2 A directory deleted with a pending edit inside it

`debug fault --writes on` makes the agent refuse every upload, so an edit in the mount stays
in the system's pending set. The directory is then deleted on the server.

**Result:**

```
   pending set: keepme/note.txt                      (count 1)
   the directory is deleted on the server
     "deleted" : 0,  "held" : 1,  "directoriesListed" : 2
   held table: path "keepme"  reason "1 deletion held in the location root"
   still in the mount? yes        the local edit: edited-on-the-mac
   status: 1 deletion(s) held in the location root, re-check at 23:44
           apply them now with: sshdrive accept-deletions m6
   accept-deletions -> Applied 1 held deletion(s) in m6.   still in the mount? NO
```

Note what is being held: the **directory**, `keepme`, while the pending edit is on
`keepme/note.txt`. A listing infers the deletion of the directory, not of the file inside
it, so the guard counts every ancestor of a pending path as pending too. Matching pending
paths exactly - which the first implementation did - would have let `keepme` through and
stranded the save inside it, which is precisely the case S5 measured. `MassDeletionGuardTests`
now covers it.

### 9.3 A mass deletion over the threshold

40 files, 30 removed on the server in one go.

**Result:**

```
rows before: 40
  "deleted" : 0,  "held" : 30
in the mount after the hold: 40
opening a file that IS still there:  f31.txt -> x
opening a HELD file (gone from the server): f01.txt
  cat: .../bulk/f01.txt: Operation timed out
status: 30 deletion(s) held in bulk, re-check at 23:45
        apply them now with: sshdrive accept-deletions m6
accept-deletions m6 bulk -> Applied 30 held deletion(s).   in the mount: 10
```

`Operation timed out` is `ETIMEDOUT`, which is `.cannotSynchronize` - never `ESTALE`, which
is what `.noSuchItem` would give (S5, 2026-09-04). Section 6.4 asks for exactly that: the
item stays, and the user is told the truth about it.

### 9.4 `status`

**Result**, on a live location:

```
m6    alec@192.168.64.1:2201   mounted  online   TTL 1h
       identity IdentityAgent=none   permissions mode   watch-mode auto
       channels 3 at a time, bulk channel, shell
       watch sweep   every 60s (active)   13 cycle(s)   3 root(s)
         note: the remote helper is not available in this version
         last cycle 0s ago: 0 changed, 2 deleted, 0 held, 1 listed, 0.05s
       30 deletion(s) held in bulk, re-check at 23:45
       apply them now with: sshdrive accept-deletions m6
       ...
       ◐ change detection   sweep (find -cmin over the root set)
             note: the remote helper is not available in this version
             upgrade: the remote helper (push events, real renames)
```

and on the busybox location the change-detection line carries the fallback and its cost:

```
m6a   ...
       watch sweep   every 60s (active)   1 cycle(s)   1 root(s)
         note: this server's find has no -cmin, so the sweep uses -mmin and a chmod,
               a chown or a write that preserved mtime is only found by the
               30-minute full sweep
       ◐ change detection   sweep (find -mmin over the root set; a rename or chmod moves
                            ctime, not mtime, so those are missed until the next full sweep)
       ◐ change evidence    size + mtime (same-second rewrites of equal size are missed)
             upgrade: a `find` that takes -printf (GNU findutils), or the helper
```

---

## 10. Teardown

```sh
sshdrive remove m6 --force; sshdrive remove m6a --force
ssh … -p 2201 alec@192.168.64.1 'rm -rf ~/m6 ~/bigtree ~/seedbig.*'
ssh … -p 2206 alec@192.168.64.1 'rm -rf ~/m6a'
```

Leave no File Provider domain, no `~/Library/CloudStorage` entry, no `sshdrive-*` control
socket and no `ssh` master behind.
